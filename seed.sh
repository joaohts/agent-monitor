#!/bin/bash
# Writes sample events to ~/.claude/agents.jsonl so the UI has something to render.
set -euo pipefail

F="$HOME/.claude/agents.jsonl"
mkdir -p "$(dirname "$F")"
: > "$F"

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
emit() { echo "$1" >> "$F"; }

emit "{\"event\":\"started\",\"session_id\":\"abc12345\",\"cwd\":\"/Users/joaohts/fun/agent-monitor\",\"ts\":\"$(now)\",\"message\":\"editing AgentMonitor.swift\"}"
emit "{\"event\":\"started\",\"session_id\":\"def67890\",\"cwd\":\"/Users/joaohts/fun/whatsapp-api\",\"ts\":\"$(now)\",\"message\":\"refactoring auth\"}"
sleep 0.3
emit "{\"event\":\"needs_attention\",\"session_id\":\"def67890\",\"ts\":\"$(now)\",\"message\":\"awaiting permission to run npm install\"}"
sleep 0.3
emit "{\"event\":\"started\",\"session_id\":\"ghi11111\",\"cwd\":\"/Users/joaohts/fun/cognee\",\"ts\":\"$(now)\",\"message\":\"running tests\"}"
sleep 0.3
emit "{\"event\":\"stopped\",\"session_id\":\"abc12345\",\"ts\":\"$(now)\",\"message\":\"task complete\"}"

echo "wrote $(wc -l < "$F") lines to $F"
