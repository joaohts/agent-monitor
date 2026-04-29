# Claude Code subagent hooks — full reference

## Two categories

1. **Lifecycle hooks** that fire in the **parent** session because of a subagent: `SubagentStart`, `SubagentStop`.
2. **Standard hooks** that fire **inside** the subagent's own session during its tool calls: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, etc.

---

## SubagentStart (parent session)

**Fires:** right after a subagent is spawned, before its first tool call.

**Payload (stdin JSON):**
```json
{
  "session_id": "parent-session-abc123",
  "agent_id": "subagent-xyz789",
  "agent_type": "Explore",
  "transcript_path": "/path/to/parent-transcript.jsonl",
  "cwd": "/project/root",
  "permission_mode": "default",
  "hook_event_name": "SubagentStart"
}
```

**Exit codes:**
- `0` — proceed (optionally return JSON with `decision`/`systemMessage`)
- `2` — block the spawn (stderr is shown to Claude as the reason)
- other — logged to debug, subagent continues

**Where to configure:** parent's `.claude/settings.json` (project) or `~/.claude/settings.json` (user). Subagent frontmatter can also declare `SubagentStart` for self-init.

**Example use:** quota / cost gating before spawning expensive agents.

---

## SubagentStop (parent session)

**Fires:** when subagent finishes, before its context is flushed and transcript archived.

**Payload:** same shape as `SubagentStart` plus `hook_event_name: "SubagentStop"`. The subagent's transcript is reachable at `transcript_path` only during the hook window.

**Exit codes:** `0` proceeds, `2` blocks the stop (rare/dangerous), other logged.

**Important auto-conversion:** if a subagent declares a `Stop` hook in its frontmatter, **Claude Code auto-converts it to `SubagentStop`** at runtime. Quoting the subagents docs:
> "When the agent is invoked as a subagent, `Stop` hooks in frontmatter are automatically converted to `SubagentStop` events."

**Example use:** archive subagent transcripts, persist findings to a memory file, fire a push notification.

---

## PreToolUse (inside subagent)

**Fires:** before every tool call the subagent makes.

**Payload (stdin JSON):**
```json
{
  "session_id": "subagent-session-def456",
  "agent_id": "subagent-xyz789",
  "agent_type": "code-reviewer",
  "transcript_path": "/path/to/subagent-transcript.jsonl",
  "cwd": "/project/root",
  "hook_event_name": "PreToolUse",
  "tool_name": "Edit",
  "tool_input": { "file_path": "/project/app.py", "edits": [] }
}
```

**Exit codes:**
- `0` — allow. Optionally return JSON with `hookSpecificOutput.updatedInput` to mutate parameters.
- `2` — block the call (stderr shown to subagent).
- other — logged, call continues.

**Inheritance:**
- Hooks in the **parent's `settings.json` apply to the subagent too** (inherited).
- Hooks in the **subagent's frontmatter** apply only to that subagent.
- Both sets run if both are defined.

**Example use:** inside a "safe-explorer" subagent, block any `Bash` command containing `rm`, `INSERT`, `UPDATE`, `DELETE`.

---

## PostToolUse (inside subagent)

**Fires:** after a tool call **succeeds**, before the result reaches the model.

**Payload:** same as `PreToolUse` plus `tool_result` (the raw output).

**Exit codes:**
- `0` — pass result through. Can return JSON `hookSpecificOutput.updatedResult` to rewrite it before the model sees it.
- `2` — non-blocking (tool already ran); stderr is surfaced to user only.

**Example use:** redact secrets from `Bash` output, append context, write an audit log.

---

## PostToolUseFailure (inside subagent)

**Fires:** after a tool call **errors** (exception, permission denied, timeout).

**Payload:** like `PostToolUse` but with `error` in place of `tool_result`.

**Exit codes:** `0` reports failure normally; `2` is non-blocking (failure already happened); other codes are logged. Can attach `additionalContext` via JSON output.

**Example use:** auto-retry recipe, escalate to a different tool, trigger a recovery script.

---

## Stop (inside subagent)

**Fires:** when the subagent's model finishes a turn and is about to wait/return.

**Payload:** standard fields, no `tool_*`.

**Exit codes:** `0` finalizes; `2` blocks the stop (subagent loops; rarely useful).

**Caveat:** in subagent **frontmatter**, declaring `Stop` is auto-rewritten to `SubagentStop` (which fires in the parent). If you really want to run something *within* the subagent's context after its last turn, you generally have to do it via `PostToolUse` on the final tool call, or via `SubagentStop` running in the parent and reading `transcript_path`.

---

## Lifecycle diagram (parent spawns Explore, Explore makes 2 tool calls)

```
PARENT
  │
  │  Claude decides to delegate
  ▼
┌──────────────────────────┐
│ SubagentStart  (parent)  │  ← exit 2 here = block spawn
└──────────────────────────┘
  │
  ▼
╔══════════ SUBAGENT SESSION (Explore) ══════════╗
║                                                ║
║  reasoning turn 1                              ║
║  │                                             ║
║  ▼                                             ║
║  PreToolUse  (subagent)   tool 1 = Read        ║
║  │                                             ║
║  ▼                                             ║
║  [tool runs]                                   ║
║  │                                             ║
║  ▼                                             ║
║  PostToolUse / PostToolUseFailure  (subagent)  ║
║  │                                             ║
║  ▼                                             ║
║  reasoning turn 2                              ║
║  │                                             ║
║  ▼                                             ║
║  PreToolUse  (subagent)   tool 2 = Bash        ║
║  │                                             ║
║  ▼                                             ║
║  [tool runs]                                   ║
║  │                                             ║
║  ▼                                             ║
║  PostToolUse  (subagent)                       ║
║  │                                             ║
║  ▼                                             ║
║  Stop  (subagent — auto-rewritten if in        ║
║         frontmatter, but doesn't fire as       ║
║         SubagentStop here)                     ║
║                                                ║
╚════════════════════════════════════════════════╝
  │
  ▼
┌──────────────────────────┐
│ SubagentStop  (parent)   │  ← transcript_path readable here
└──────────────────────────┘
  │
  ▼
PARENT resumes with subagent's summary
  │
  ▼
Parent's Stop hook fires (when parent's whole turn ends)
```

---

## Where each hook is configured

| Hook | Subagent frontmatter | Parent `settings.json` | User `~/.claude/settings.json` |
|---|---|---|---|
| `SubagentStart` | self-init only | yes (typical) | yes |
| `SubagentStop` | **auto-rewrite from `Stop`** | yes (typical) | yes |
| `PreToolUse` / `PostToolUse` / `PostToolUseFailure` | scoped to that subagent | inherited by all subagents | inherited by all subagents |
| `Stop` | auto-rewrites to `SubagentStop` in frontmatter | parent-only | parent-only |

Matchers are **regex against tool name** (or agent_type for Subagent* events): `"Bash"` matches only `Bash`; use `"Bash.*"` or `"Bash|Edit"` for broader matches.

---

## Pitfalls people hit

1. **`Stop` ≠ `SubagentStop`.** Declaring `Stop` in subagent frontmatter is auto-converted to `SubagentStop` (fires in parent, not in the subagent). Don't expect "run cleanup inside the subagent on stop" to work that way.
2. **Inheritance is one-way.** Parent settings.json hooks fire inside subagents; subagent frontmatter hooks do **not** apply to the parent.
3. **Wrong cwd.** Hooks run with the `cwd` field from the payload. Always read it from stdin rather than trusting `$PWD`:
   ```bash
   CWD=$(jq -r '.cwd' <<<"$INPUT"); cd "$CWD"
   ```
4. **Env vars don't propagate.** Setting an env var in a parent hook doesn't reach a subagent's hooks. Use `$CLAUDE_ENV_FILE` (where supported) or write to a state file.
5. **Exit-2 only blocks pre-events.** `PostToolUse` / `PostToolUseFailure` already fired by the time the hook runs — exit 2 there only surfaces stderr, doesn't undo.
6. **Concurrent subagents → race conditions.** Parallel forks fire hooks simultaneously. Use `flock` on shared logs.
7. **Deny rules vs subagent allowlist.** A subagent's `tools:` frontmatter is an allowlist, but `permissions.deny` patterns in `settings.json` still bind both parent and subagent.

---

**Sources:** `code.claude.com/docs/en/hooks.md` (event reference, matchers, exit codes) and `code.claude.com/docs/en/subagents.md` (Stop→SubagentStop auto-conversion, frontmatter hook syntax).

> Caveat: `PostToolUseFailure`, `PermissionRequest`, and `PostToolBatch` are referenced by some sources without direct doc quotes — treat them as likely-but-unconfirmed and verify against the docs for your CLI version. The core four (`SubagentStart`, `SubagentStop`, `PreToolUse`, `PostToolUse`) are well-documented.
