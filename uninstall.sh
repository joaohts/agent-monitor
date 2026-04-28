#!/bin/bash
# Reverses install.sh:
# - Stops the running app
# - Removes ~/Applications/AgentMonitor.app symlink
# - Removes our hook entries from ~/.claude/settings.json (with backup)
# Does NOT delete user data (~/.claude/agents.jsonl, debug log) by default.
set -euo pipefail
cd "$(dirname "$0")"

REPO_DIR="$(pwd)"
HOOK_PATH="$REPO_DIR/hooks/agent-monitor-hook.sh"
SETTINGS="$HOME/.claude/settings.json"
APP_LINK="$HOME/Applications/AgentMonitor.app"

echo "==> Agent Monitor uninstaller"
echo "    repo:    $REPO_DIR"
echo "    hook:    $HOOK_PATH"
echo

# ── 1. Stop running app ─────────────────────────────────────────────────────
if pgrep -x AgentMonitor >/dev/null 2>&1; then
    echo "==> Stopping AgentMonitor..."
    pkill -x AgentMonitor || true
    sleep 0.2
    echo "    ✓ stopped"
else
    echo "==> AgentMonitor not running, skipping"
fi
echo

# ── 2. Remove ~/Applications symlink ────────────────────────────────────────
if [ -L "$APP_LINK" ]; then
    echo "==> Removing $APP_LINK..."
    rm -f "$APP_LINK"
    echo "    ✓ removed symlink"
elif [ -e "$APP_LINK" ]; then
    echo "==> $APP_LINK exists but isn't a symlink — leaving it alone"
    echo "    (remove manually if you want: rm -rf '$APP_LINK')"
else
    echo "==> No symlink at $APP_LINK, skipping"
fi
echo

# ── 3. Remove our hook entries from settings.json ───────────────────────────
if [ ! -f "$SETTINGS" ]; then
    echo "==> No $SETTINGS, skipping hook unregistration"
else
    if ! command -v jq >/dev/null 2>&1; then
        echo "==> jq not installed; cannot safely edit $SETTINGS"
        echo "    Manually remove entries pointing to $HOOK_PATH from .hooks"
    else
        BACKUP="$SETTINGS.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SETTINGS" "$BACKUP"
        echo "==> Removing our hook entries from $SETTINGS..."
        echo "    backup saved: $BACKUP"

        TMP=$(mktemp)
        # For each event we registered, drop matchers whose any inner command == our hook path.
        # If the resulting array is empty, remove the event key entirely.
        # If .hooks ends up empty, remove the .hooks key.
        jq --arg cmd "$HOOK_PATH" '
        def filter_event(name):
            if .hooks[name] then
                .hooks[name] |= map(select((.hooks // []) | any(.command == $cmd) | not))
                | if (.hooks[name] | length) == 0 then del(.hooks[name]) else . end
            else . end;
        filter_event("SessionStart")
        | filter_event("UserPromptSubmit")
        | filter_event("Notification")
        | filter_event("Stop")
        | filter_event("SessionEnd")
        | if (.hooks // {}) == {} then del(.hooks) else . end
        ' "$SETTINGS" > "$TMP"

        if jq -e . "$TMP" >/dev/null 2>&1; then
            mv "$TMP" "$SETTINGS"
            echo "    ✓ unregistered: SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd"
            echo "    (other tools' hooks preserved)"
        else
            echo "    ✗ jq produced invalid JSON; settings.json untouched"
            rm -f "$TMP"
            exit 1
        fi
    fi
fi
echo

# ── 4. Done ─────────────────────────────────────────────────────────────────
cat <<EOF
==> Uninstall complete.

Preserved (user data — delete manually if you want):
  ~/.claude/agents.jsonl                      (event log)
  ~/.claude/agent-monitor-debug.log           (debug log)
  $REPO_DIR/AgentMonitor.app                 (build artifact)
  $REPO_DIR                                   (repo)

To reinstall later:
  ./install.sh
EOF
