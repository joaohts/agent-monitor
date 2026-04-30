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
        # Claude Code sends two flavors of Notification:
        #   permission_prompt → real attention needed
        #   idle_prompt       → 60s "waiting for your input" nudge; ignore
        NTYPE=$(echo "$INPUT" | jq -r '.notification_type // ""' 2>/dev/null)
        if [ "$NTYPE" = "idle_prompt" ]; then
            exit 0
        fi
        EVENT="needs_attention"
        MSG=$(echo "$INPUT" | jq -r '.message // "needs attention"' 2>/dev/null)
        ;;
    Stop)
        EVENT="stopped"
        MSG="turn complete"
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

jq -nc \
    --arg event "$EVENT" \
    --arg session_id "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg ts "$TS" \
    --arg message "$MSG" \
    --arg transcript "$TRANSCRIPT" \
    --arg agent_type "$AGENT_TYPE" \
    --arg parent_sid "$PARENT_SID" \
    '{event: $event, session_id: $session_id, cwd: $cwd, ts: $ts, message: $message, transcript_path: $transcript}
     + (if $agent_type != "" then {agent_type: $agent_type} else {} end)
     + (if $parent_sid  != "" then {parent_session_id: $parent_sid} else {} end)' \
    >> "$OUT" 2>/dev/null

exit 0
