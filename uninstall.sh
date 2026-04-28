#!/bin/bash
# Full uninstall: clean slate, as if you'd never installed Agent Monitor.
# - Stops the running app
# - Removes ~/Applications/AgentMonitor.app symlink
# - Removes our hook entries from ~/.claude/settings.json (with backup)
# - Deletes ~/.claude/agents.jsonl (event log)
# - Deletes ~/.claude/agent-monitor-debug.log (debug log)
# - Removes the AgentMonitor.app build artifact in the repo
# Does NOT delete the repo itself — git rm or rm -rf manually if you want.
# Does NOT revoke TCC permissions — see message at end for manual steps.
#
# Pass --keep-data to preserve agents.jsonl and the debug log.
set -euo pipefail
cd "$(dirname "$0")"

KEEP_DATA=0
[ "${1:-}" = "--keep-data" ] && KEEP_DATA=1

REPO_DIR="$(pwd)"
HOOK_PATH="$REPO_DIR/hooks/agent-monitor-hook.sh"
SETTINGS="$HOME/.claude/settings.json"
APP_LINK="$HOME/Applications/AgentMonitor.app"
EVENTS_LOG="$HOME/.claude/agents.jsonl"
DEBUG_LOG="$HOME/.claude/agent-monitor-debug.log"
APP_BUNDLE="$REPO_DIR/AgentMonitor.app"

echo "==> Agent Monitor uninstaller"
echo "    repo:    $REPO_DIR"
echo "    hook:    $HOOK_PATH"
[ $KEEP_DATA -eq 1 ] && echo "    mode:    --keep-data (will preserve event log + debug log)"
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

# ── 4. Remove build artifact ────────────────────────────────────────────────
if [ -d "$APP_BUNDLE" ]; then
    echo "==> Removing build artifact $APP_BUNDLE..."
    rm -rf "$APP_BUNDLE"
    echo "    ✓ removed (rebuild anytime with ./build.sh)"
else
    echo "==> No build artifact at $APP_BUNDLE, skipping"
fi
echo

# ── 5. Remove user data (event log, debug log) ──────────────────────────────
if [ $KEEP_DATA -eq 1 ]; then
    echo "==> Skipping user data deletion (--keep-data was passed)"
else
    for f in "$EVENTS_LOG" "$DEBUG_LOG"; do
        if [ -f "$f" ]; then
            echo "==> Removing $f..."
            rm -f "$f"
            echo "    ✓ removed"
        fi
    done
fi
echo

# ── 6. Done ─────────────────────────────────────────────────────────────────
cat <<EOF
==> Uninstall complete. Clean slate.

Not auto-revoked (manual cleanup if you want):
  - TCC permissions (Full Disk Access, etc): System Settings → Privacy & Security
  - settings.json backups (.bak.YYYYMMDD_HHMMSS): kept as safety nets
  - The repo itself ($REPO_DIR): \`rm -rf\` or \`git clean\` manually

To reinstall later:
  ./install.sh
EOF
