#!/bin/bash
# One-shot installer for Agent Monitor.
# - Verifies prereqs (swiftc, jq, claude CLI)
# - Builds AgentMonitor.app
# - Merges hook config into ~/.claude/settings.json (idempotent, with backup)
set -euo pipefail
cd "$(dirname "$0")"

REPO_DIR="$(pwd)"
HOOK_PATH="$REPO_DIR/hooks/agent-monitor-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

echo "==> Agent Monitor installer"
echo "    repo:    $REPO_DIR"
echo "    hook:    $HOOK_PATH"
echo

# ── 1. Prereqs ───────────────────────────────────────────────────────────────
echo "==> Checking prerequisites..."
missing=()
command -v swiftc >/dev/null 2>&1 || missing+=("Swift compiler — run: xcode-select --install")
command -v jq     >/dev/null 2>&1 || missing+=("jq — run: brew install jq")
command -v claude >/dev/null 2>&1 || missing+=("claude CLI — install from https://claude.ai/code")

if [ ${#missing[@]} -gt 0 ]; then
    echo "    ✗ missing prerequisites:"
    for m in "${missing[@]}"; do echo "      - $m"; done
    echo
    echo "Install the above and re-run ./install.sh"
    exit 1
fi
echo "    ✓ swiftc, jq, claude all found"
echo

# ── 2. Build ─────────────────────────────────────────────────────────────────
echo "==> Building AgentMonitor.app..."
chmod +x "$HOOK_PATH" build.sh
./build.sh
echo

# ── 3. Verify hook script runs cleanly with sample input ────────────────────
echo "==> Smoke-testing hook script..."
LINES_BEFORE=$(wc -l < "$HOME/.claude/agents.jsonl" 2>/dev/null || echo 0)
echo '{"session_id":"install_smoke","cwd":"/tmp","hook_event_name":"SessionStart"}' \
    | "$HOOK_PATH"
LINES_AFTER=$(wc -l < "$HOME/.claude/agents.jsonl" 2>/dev/null || echo 0)
if [ "$LINES_AFTER" -gt "$LINES_BEFORE" ]; then
    echo "    ✓ hook wrote 1 event"
    # Clean up the smoke-test session
    echo '{"session_id":"install_smoke","cwd":"/tmp","hook_event_name":"SessionEnd"}' \
        | "$HOOK_PATH"
else
    echo "    ✗ hook didn't write — check $HOME/.claude/agent-monitor-debug.log"
    exit 1
fi
echo

# ── 4. Merge hooks into ~/.claude/settings.json ─────────────────────────────
echo "==> Configuring hooks in $SETTINGS..."
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak.$(date +%Y%m%d_%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "    backup saved: $BACKUP"

TMP=$(mktemp)
jq --arg cmd "$HOOK_PATH" '
def add_hook(name):
    if ([.hooks[name][]?.hooks[]?.command] | any(. == $cmd)) then
        .
    else
        .hooks[name] = ((.hooks[name] // []) + [{"hooks":[{"type":"command","command":$cmd}]}])
    end;
(.hooks //= {})
| add_hook("SessionStart")
| add_hook("UserPromptSubmit")
| add_hook("Notification")
| add_hook("Stop")
| add_hook("SessionEnd")
| add_hook("SubagentStart")
| add_hook("SubagentStop")
' "$SETTINGS" > "$TMP"

if jq -e . "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$SETTINGS"
    echo "    ✓ registered: SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd, SubagentStart, SubagentStop"
else
    echo "    ✗ jq produced invalid JSON; settings.json untouched"
    rm -f "$TMP"
    exit 1
fi
echo

# ── 5. Symlink into ~/Applications so Spotlight can find it ─────────────────
APPS_DIR="$HOME/Applications"
APP_LINK="$APPS_DIR/AgentMonitor.app"
APP_TARGET="$REPO_DIR/AgentMonitor.app"

mkdir -p "$APPS_DIR"

# Replace any existing symlink/copy with a fresh symlink to our build location
if [ -L "$APP_LINK" ] || [ -e "$APP_LINK" ]; then
    rm -rf "$APP_LINK"
fi
ln -s "$APP_TARGET" "$APP_LINK"
echo "==> Symlinked $APP_LINK → $APP_TARGET"
echo "    (search 'Agent Monitor' in Spotlight to launch it)"
echo

# ── 6. Done ─────────────────────────────────────────────────────────────────
cat <<EOF
==> Installation complete.

The floating window should now be visible. New Claude Code sessions you start in
any terminal will appear in it automatically.

First-launch notes:
  - On first AI title generation, macOS may prompt for Full Disk Access.
    Allow → AI titles + live status work.
    Deny  → basic features still work, no AI titles.
  - If Gatekeeper says "cannot verify developer": right-click AgentMonitor.app → Open.
  - Photo Library / Desktop prompts are false positives — click Don't Allow.

Useful paths:
  state:  ~/.claude/agents.jsonl
  debug:  ~/.claude/agent-monitor-debug.log
  config: $SETTINGS
  backup: $BACKUP

To rebuild after editing AgentMonitor.swift:
  ./build.sh

To remove the hooks: edit $SETTINGS or restore from $BACKUP.
EOF
