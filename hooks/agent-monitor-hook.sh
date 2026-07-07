#!/bin/bash
# Claude Code hook → appends one event to ~/.claude/agents.jsonl
# Designed to never block or fail Claude Code: silent on errors, always exit 0.

# Skip when invoked by Agent Monitor's own internal subprocesses (e.g., title generator)
[ -n "${AGENT_MONITOR_INTERNAL:-}" ] && exit 0

OUT="$HOME/.claude/agents.jsonl"
mkdir -p "$(dirname "$OUT")" 2>/dev/null

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
HOOK=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0
[ -z "$HOOK" ] && exit 0

# Debug: log every hook firing (delete this line later)
echo "[$(date +%H:%M:%S)] $HOOK ${SESSION_ID:0:8}" >> "$HOME/.claude/agent-monitor-debug.log" 2>/dev/null

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT_TYPE=""
PARENT_SID=""

case "$HOOK" in
    SessionStart)
        EVENT="idle"
        MSG="session start"
        ;;
    UserPromptSubmit)
        EVENT="started"
        MSG="user prompt"
        ;;
    Notification)
        # Claude Code sends several Notification flavors via notification_type:
        #   permission_prompt → real attention needed (legacy path; now also covered
        #                       by the dedicated PermissionRequest hook below)
        #   idle_prompt       → 60s "waiting for your input" nudge; ignore
        #   auth_success / elicitation_*, etc → ignore
        # Treat only permission_prompt as needs_attention; everything else skip.
        NTYPE=$(echo "$INPUT" | jq -r '.notification_type // ""' 2>/dev/null)
        if [ "$NTYPE" != "permission_prompt" ]; then
            exit 0
        fi
        EVENT="needs_attention"
        MSG=$(echo "$INPUT" | jq -r '.message // "needs attention"' 2>/dev/null)
        ;;
    PermissionRequest)
        # Fires when Claude Code shows a permission dialog. This is the modern
        # path for permission asks; older versions used Notification with
        # notification_type=permission_prompt.
        EVENT="needs_attention"
        MSG=$(echo "$INPUT" | jq -r '.message // "permission required"' 2>/dev/null)
        ;;
    Stop)
        EVENT="stopped"
        MSG="turn complete"
        ;;
    StopFailure)
        # Turn ended due to an API error (529 overloaded, rate_limit, server_error,
        # billing_error, etc). Emits a dedicated api_error event so the app can show
        # a distinct RED status instead of looking like a clean turn end. The catch-all
        # StopFailure registration (no matcher) means every error type lands here; the
        # specific type travels in MSG. Field is error_type per the hooks docs; older
        # payloads used .error, so fall back to it.
        EVENT="api_error"
        MSG=$(echo "$INPUT" | jq -r '.error_type // .error // "unknown"' 2>/dev/null)
        ;;
    Elicitation)
        # MCP server is asking the user for input — same flavor of "blocked
        # waiting on you" as a permission prompt.
        EVENT="needs_attention"
        MSG=$(echo "$INPUT" | jq -r '.message // "MCP server needs input"' 2>/dev/null)
        ;;
    SessionEnd)
        EVENT="cleared"
        MSG="session ended"
        ;;
    SubagentStart|SubagentStop)
        # Subagent lifecycle hooks fire in the parent session.
        # We re-key the row by agent_id so the subagent gets its own row,
        # and stash agent_type + parent_session_id for the app to render.
        AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
        AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
        [ -z "$AGENT_ID" ] && exit 0
        PARENT_SID="$SESSION_ID"
        SESSION_ID="$AGENT_ID"
        if [ "$HOOK" = "SubagentStart" ]; then
            EVENT="started"
        else
            EVENT="stopped"
        fi
        MSG=""
        ;;
    *)
        exit 0
        ;;
esac

# Capture the Ghostty terminal id for this session. At SessionStart /
# UserPromptSubmit the user is acting in this exact tab, so the focused terminal
# of the front window IS this session's terminal. Guarded by cwd so a stray
# focus on another window doesn't record the wrong tab. Empty if not in Ghostty.
TERMINAL_ID=""
if { [ "$HOOK" = "SessionStart" ] || [ "$HOOK" = "UserPromptSubmit" ]; } \
   && [ "$TERM_PROGRAM" = "ghostty" ] && command -v osascript >/dev/null 2>&1; then
    TERMINAL_ID=$(osascript - "$CWD" <<'OSA' 2>/dev/null
on run argv
    set targetCwd to item 1 of argv
    tell application "Ghostty"
        try
            set t to focused terminal of selected tab of front window
            if (working directory of t) is targetCwd then return (id of t)
        end try
    end tell
    return ""
end run
OSA
)
fi

jq -nc \
    --arg event "$EVENT" \
    --arg session_id "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg ts "$TS" \
    --arg message "$MSG" \
    --arg transcript "$TRANSCRIPT" \
    --arg agent_type "$AGENT_TYPE" \
    --arg parent_sid "$PARENT_SID" \
    --arg terminal_id "$TERMINAL_ID" \
    '{event: $event, session_id: $session_id, cwd: $cwd, ts: $ts, message: $message, transcript_path: $transcript}
     + (if $agent_type  != "" then {agent_type: $agent_type} else {} end)
     + (if $parent_sid  != "" then {parent_session_id: $parent_sid} else {} end)
     + (if $terminal_id != "" then {terminal_id: $terminal_id} else {} end)' \
    >> "$OUT" 2>/dev/null

exit 0
