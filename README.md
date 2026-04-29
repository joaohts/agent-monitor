# Agent Monitor

A native macOS floating window that shows live status of every running Claude Code session across your machine. Status, runtime, AI-generated titles, and live "what's happening now" descriptions, all driven by Claude Code hooks writing JSON-line events.

Built in a single Swift file with no external dependencies (no Xcode project, no Swift Package Manager). Compiles to a `.app` bundle in ~3 seconds.

---

## What it does

- **Always-on-top floating window** that lists every Claude Code session you have open
- Live status per session: `idle`, `running`, `away`, `needs attention`, `stopped`
- Per-turn runtime timer that ticks while running and freezes on stop
- AI-generated session titles via a side-car `claude -p` call
- Live "what's happening right now" subtitle while a session is actively processing
- Sound alerts when a session needs your attention or finishes
- Two-column layout: things that need you on the left, active sessions on the right

All state lives in `~/.claude/agents.jsonl`. Claude Code hooks append events; the app reads and renders.

---

## Architecture

```
┌─ Claude Code (any session, any project) ─┐
│   SessionStart, UserPromptSubmit,         │     hooks fire
│   Notification, Stop, SessionEnd          │ ───────────────► hook script
└───────────────────────────────────────────┘                       │
                                                                    ▼
                                          ┌────────────────────────────┐
                                          │ agent-monitor-hook.sh      │
                                          │ - parses Claude's JSON     │
                                          │ - filters idle_prompt      │
                                          │ - skips internal subproc   │
                                          │ - appends 1 line of JSON   │
                                          └─────────────┬──────────────┘
                                                        ▼
                                          ┌────────────────────────────┐
                                          │ ~/.claude/agents.jsonl     │
                                          │ (append-only event log)    │
                                          └─────────────┬──────────────┘
                                                        ▼ (kqueue + 1Hz poll)
                                          ┌────────────────────────────┐
                                          │ AgentMonitor.app           │
                                          │ - replays events           │
                                          │ - reads transcripts        │
                                          │ - spawns claude -p for AI  │
                                          │ - renders SwiftUI window   │
                                          └────────────────────────────┘
```

### Why JSONL?

Hooks are external shell scripts. Appending one JSON line is trivial (`echo >> file`). POSIX guarantees atomic appends under `O_APPEND` for writes ≤ `PIPE_BUF` (≥4KB on macOS), so 50 concurrent sessions can write at once without corruption.

### Files involved

| Path | Purpose |
|---|---|
| `AgentMonitor.swift` | Single-file SwiftUI app (~700 lines) |
| `build.sh` | Compiles to `.app` bundle, kills prior instance, launches |
| `hooks/agent-monitor-hook.sh` | The Claude Code hook script |
| `~/.claude/agents.jsonl` | Event log (the database) |
| `~/.claude/settings.json` | Where the hooks are registered globally |
| `~/.claude/projects/*/*.jsonl` | Claude's own per-session transcripts (we read for titles) |
| `~/.claude/agent-monitor-debug.log` | Hook + `claude -p` debug output |

---

## Install

### Prerequisites

- macOS 13+ (uses `URL.appending(path:)`)
- Xcode Command Line Tools (`swiftc`, `xcodebuild`) — install with `xcode-select --install`
- `jq` — `brew install jq`
- `claude` CLI logged in (for AI title and live-status features)

### One-shot install (recommended)

```bash
cd /path/to/agent-monitor
./install.sh
```

This script:
- Verifies prereqs (`swiftc`, `jq`, `claude` CLI) and prints install hints if any are missing
- Builds `AgentMonitor.app` via `build.sh`
- Smoke-tests the hook script with sample input
- **Idempotent merge** of hook entries into `~/.claude/settings.json` via `jq`:
  - Existing hooks for other tools are preserved (added as additional matchers, not overwritten)
  - Re-running won't duplicate our entries (detects our hook path is already registered)
  - Backup of `settings.json` saved as `settings.json.bak.YYYYMMDD_HHMMSS` before any change
  - If `jq` produces invalid JSON, the original is left untouched and the script exits non-zero
- Prints next-step instructions for TCC prompts

### Uninstall

```bash
./uninstall.sh             # full clean slate
./uninstall.sh --keep-data # preserve agents.jsonl + debug log
```

The default is a complete clean slate:
- Stops the running app
- Removes the `~/Applications/AgentMonitor.app` symlink
- Unregisters our hooks from `~/.claude/settings.json` (preserves other tools' hooks; saves a backup first)
- Deletes the `AgentMonitor.app` build artifact in the repo
- Deletes `~/.claude/agents.jsonl` and `~/.claude/agent-monitor-debug.log`

Not auto-handled (deliberately):
- **TCC permissions** (Full Disk Access etc) — revoke manually in System Settings → Privacy & Security
- **`settings.json.bak.*` backups** — kept as safety nets, rm them yourself
- **The repo itself** — `rm -rf` or `git clean` manually

### Manual install

If you'd rather do it by hand:

```bash
cd /path/to/agent-monitor
./build.sh           # compiles + launches AgentMonitor.app
```

Then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":     [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "Notification":     [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "Stop":             [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "SessionEnd":       [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}]
  }
}
```

The first time you trigger an AI title (or live status), macOS may prompt for **Full Disk Access** (because the app reads transcripts in `~/.claude/projects/`, written by another signed app). Grant or deny — denying just disables AI titles, everything else still works.

### Build modes

```bash
./build.sh           # debug build (~3s, recommended for iteration)
RELEASE=1 ./build.sh # optimized build (~15s)
```

---

## Use

Run `./build.sh` once. From then on the app sits in your menu/dock and the floating window stays above other windows.

### Window behavior

- **Floating** (`.windowLevel = .floating`) — stays above non-floating windows
- **Visible on all Spaces** (`canJoinAllSpaces` collection behavior)
- **Movable by background** — drag from anywhere in the window
- Standard traffic-light buttons: minimize, close, zoom
- **Spotlight-launchable** — installer symlinks `AgentMonitor.app` into `~/Applications`, so `Cmd+Space → "Agent Monitor"` works
- **Custom dock/Spotlight icon** generated from `assets/icon.png` on every build (auto-padded to square + scaled to all 10 required iconset sizes)

### Header bar

| Icon | Function |
|---|---|
| Count badge | Total agents in the list |
| ✨ sparkles | Toggle AI title + live-status generation (saves tokens when off) |
| 🔔 bell | Toggle push notifications to phone (disabled if jsplayground not configured) |
| 🔊 / 🔇 speaker | Mute / unmute transition sounds |
| ↻ arrow | Force reload from `agents.jsonl` |

### Per-row interaction

- **Hover** — row highlights, X button becomes opaque
- **Click X** — appends a `cleared` event, removes the agent
- **Right-click** — context menu: *Dismiss session* / *Copy session ID*

---

## Statuses

| Status | Color | Column | When | Timer |
|---|---|---|---|---|
| `idle` | 🔵 blue | left | `SessionStart` fires; session opened, no prompt yet | not running |
| `running` | 🟢 green | right | `UserPromptSubmit` fires; Claude actively processing | live ticking |
| `away` | 🟡 yellow | right | Auto: transcript silent for >60s and run age >60s | keeps ticking, dimmed |
| `needs attention` | 🟠 orange | left | `Notification` with `notification_type: permission_prompt` | frozen |
| `stopped` | ⚪ gray | left | `Stop` hook fires (turn done) | frozen at stop time |

**Sort order within columns:** `needsAttention < running < away < stopped < idle` then by recency.

### Row layout

```
project-name #1                                   ← cwd basename + sibling index
0:42 · running · sonnet-4.6                       ← time · status · model alias
writing Swift app monitor                         ← live status (callout font, white) while running
                                                    ↳ persistent generated title (caption font, gray) when not
```

The third metadata token is the **model** in use, parsed from the most recent assistant entry in the transcript (e.g. `sonnet-4.6`, `opus-4.7`, `haiku-4.5`). Falls back to a session ID prefix for brand-new sessions where no transcript exists yet.

### Status transitions

```
                    UserPromptSubmit
       ┌──────────────────────────────────┐
       ▼                                  │
  ┌────────┐  Notification (permission)   │
  │ idle   │ ──────────────────────────►  │
  └────────┘            ┌─ needs attention ─┐
       ▲                │                    │
       │ SessionStart   │  resumes/continues │
       │                ▼                    ▼
       │           ┌──────────┐ ◄───── Stop ──┐
       │           │ running  │                │
       │           └────┬─┬───┘                │
       │                │ │ no transcript      │
       │                │ │ writes for >60s    │
       │                │ ▼                    │
       │                │ ┌────────┐           │
       │                │ │ away   │           │
       │                │ └────┬───┘           │
       │                │      │ activity      │
       │                │      │ resumes       │
       │                │      ▼               │
       │                └─────────────────────►│
       │                                       ▼
       │                                  ┌─────────┐
       └─────── SessionEnd ──── (cleared) │ stopped │
                                          └─────────┘
```

Timer behavior:
- Resets to 0 on each `started` event (per-turn timing)
- Freezes when entering `needs attention` or `stopped`
- Keeps ticking visually in `away` (treated as "still running, just quiet")

---

## The AI features

Two independent generators that both shell out to `claude -p --model claude-haiku-4-5`. Both gated by the ✨ sparkles toggle.

### 1. Persistent title (`TitleGenerator`)

**Triggers:** at 3 user messages, then every +20.

**Excerpt sent:** first 2 turns + last 6 turns (capped at 600 chars each), plus latest auto-summary if present (capped at 1200 chars).

**Prompt:**
> Below is excerpts from a Claude Code session. Generate a concise 5-7 word title summarizing what this session is about. Output ONLY the title — no quotes, no trailing punctuation, no preamble.

**Display:** shows in the row's **subtitle** (caption font, gray) when status is *not* running. Persists across status changes.

### 2. Live status (`LiveStatusGenerator`)

**Triggers:** status is `.running` AND elapsed run time ≥ 15s, throttled to once per 60s per session.

**Excerpt sent:** last 5 user messages + every assistant turn following each, in order. Plus latest auto-summary if present.

**Prompt:**
> You are observing an in-progress Claude Code session. Below is the recent context: the last few user messages and Claude's responses, plus an optional earlier summary.
>
> Generate a concise 5-7 word phrase describing EXACTLY what Claude is doing RIGHT NOW — the most recent action in progress. Use present-continuous, action-focused language (e.g. "writing Swift app", "debugging failing tests", "refactoring auth module").
>
> IMPORTANT: the phrase will be truncated to ~50 characters when displayed. Front-load the most informative words — the core meaning MUST be conveyed in the first 50 characters even if the rest is cut off.
>
> Output ONLY the phrase — no quotes, no preamble, no trailing punctuation.

**Display:** **takes over the subtitle slot** (replacing the persistent title) while the session is `.running`. Rendered in **callout font, medium weight, primary color** to visually distinguish from the persistent title (caption, secondary). When status leaves running, the persistent title returns.

### Subprocess hygiene

Every `claude -p` call from the app:
- Sets env `AGENT_MONITOR_INTERNAL=1` — the hook script exits early when it sees this, so the side-car subprocess doesn't appear in the monitor as its own session
- Pins `cwd` to `/tmp` — prevents inheriting a TCC-protected directory (Desktop/Documents/Downloads) and triggering cascading permission prompts
- Captures stderr to `~/.claude/agent-monitor-debug.log` for diagnostics

### Output sanitization

Both generators run output through `ClaudeP.sanitizeShortPhrase`:
- Trim whitespace and newlines
- Take only the first line
- Strip wrapping quotes (`"`, `'`, `` ` ``)
- Strip trailing `.`, `!`, `?`, `…`

---

## Push notifications (optional)

The 🔔 bell button in the header sends pushes to your phone via the **jsplayground MCP server** when:

- A session transitions to **`.needsAttention`** → urgent push: `🟠 <project> needs attention`
- A session transitions to **`.idle`** from `running` / `away` / `needs_attention` (real turn completion) → info push: `✅ <project> finished`

Skipped: brand-new sessions (`nil → idle`), automatic decay (`idle → inactive`), all other transitions.

### Configuration

The app reads jsplayground server config from `~/.claude.json` at launch. Add this block under `mcpServers`:

```json
{
  "mcpServers": {
    "jsplayground": {
      "type": "http",
      "url": "https://mcp.jsplayground.cc/mcp",
      "headers": {
        "Authorization": "Bearer <YOUR_TOKEN>"
      }
    }
  }
}
```

Token comes from however jsplayground issues them (it's João's personal Pager API service — not generally available).

### Button states

- **Configured + on** — `bell.badge.fill` in accent color, sending pushes
- **Configured + off** — outline `bell` in secondary color, dormant
- **Not configured** — grayed out + disabled, tooltip explains how to enable

The on/off toggle is persisted to `UserDefaults` so it survives app restarts. The config itself is read once at app launch, so if you edit `~/.claude.json` you must restart the app:

```bash
pkill -x AgentMonitor && open ~/Applications/AgentMonitor.app
```

### Wire format

The app posts JSON-RPC `tools/call` for the `send_push` tool to the configured endpoint:

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "method": "tools/call",
  "params": {
    "name": "send_push",
    "arguments": {
      "title": "🟠 agent-monitor needs attention",
      "message": "<live status / last hook message>",
      "category": "urgent",
      "source": "agent-monitor"
    }
  }
}
```

With `Authorization: Bearer <token>`. Failures are silent (logged to `~/.claude/agent-monitor-debug.log` with `push:` prefix).

---

## The hook script (`agent-monitor-hook.sh`)

A single bash script registered for 5 hooks. Designed to never block or fail Claude Code.

| Claude hook | Mapped event | Notes |
|---|---|---|
| `SessionStart` | `idle` | Session opened, no prompt yet |
| `UserPromptSubmit` | `started` | New run begins; resets the timer |
| `Notification` (`permission_prompt`) | `needs_attention` | Real attention needed |
| `Notification` (`idle_prompt`) | *(skipped)* | The 60s "Claude is waiting for your input" nudge — ignored |
| `Stop` | `stopped` | Turn finished |
| `SessionEnd` | `cleared` | Removes from list |

### Skip conditions (the script exits 0 silently)

1. `AGENT_MONITOR_INTERNAL=1` env var set (our own subprocess)
2. Empty stdin
3. Missing `session_id` or `hook_event_name` in the input
4. `notification_type == idle_prompt` (idle nudge, not real attention)
5. Unknown hook name

### Event format

```json
{"event":"started","session_id":"abc12345","cwd":"/path/to/proj","ts":"2026-04-28T03:42:01Z","message":"user prompt","transcript_path":"/Users/.../session_id.jsonl"}
```

---

## Smart features and edge cases

### Concurrent multi-session writes
All sessions write to one global `~/.claude/agents.jsonl`. POSIX atomic-append under `O_APPEND` guarantees no interleaving for lines under 4KB.

### Sibling indexing
Multiple sessions with the same `cwd` show as `project-name #1`, `project-name #2`, ordered by `firstSeen`. The base name is the cwd's last path component.

### Idle prompt filtering
Claude's `Notification` hook fires both for permission prompts (real attention) and the 60-second "waiting for your input" nudge. The hook script reads `notification_type` and skips `idle_prompt` so the row doesn't flicker into needs_attention every minute.

### `.away` detection (transcript polling)
- Watches the per-session transcript file's mtime
- If silent for >60s AND the run has been going for >60s, mark `.away`
- Anchored against `runStartedAt` so freshly-started runs don't immediately appear away (the previous turn's mtime no longer counts)
- If activity resumes (transcript writes), automatically flips back to `.running` on next reload
- Never auto-transitions to `.stopped` — only a real `Stop` event does that

This is a heuristic. Limitations:
- Long thinking pauses (>60s before first token) will trigger `.away` briefly
- Long tool executions don't trigger `.away` (we check `tool_use` IDs and skip if any are unmatched)
- Truly interrupted sessions never go to `.stopped` — they sit at `.away` forever (use the X button to dismiss)

### Periodic reload
When any agent is `.running`, a 1Hz `Timer` calls `reload()` so the staleness check and live-status generation re-evaluate even when no new events arrive.

### Title/excerpt caching
`TranscriptReader` caches parsed transcript info keyed by file mtime. Re-reads only when the file actually changes, so reloads are fast even with many sessions.

---

## Tunable constants (in `AgentMonitor.swift`)

```swift
// AgentStore
static let awayThresholdSec: TimeInterval = 60      // .running → .away
static let staleCheckInterval: TimeInterval = 1     // periodic reload while running

// LiveStatusGenerator
static let minRunSeconds: TimeInterval = 15         // gate live status until run is ≥15s
static let minIntervalSeconds: TimeInterval = 60    // throttle: ≥60s between calls per session

// TranscriptReader
static let headTurns          = 2                   // title: first N turns
static let tailTurns          = 6                   // title: last N turns
static let liveUserMessages   = 5                   // live status: last N user msgs + their assistant turns
static let perTurnCharCap     = 600                 // truncate each turn's text
static let summaryCharCap     = 1200                // truncate auto-summary if huge
```

---

## What's NOT implemented (deliberate choices)

- **Persistent settings** — sound mute and AI toggle reset on every app launch (not saved to UserDefaults). Could add ~10 LOC.
- **Instant interrupt detection** — no clean way without Anthropic adding an Interrupt hook. The `.away` heuristic is the best we can do externally.
- **Window position persistence** — opens at the same place each launch.
- **Code signing / notarization** — local personal app only.
- **Log rotation** — `agents.jsonl` grows forever. Manual: `: > ~/.claude/agents.jsonl` to truncate.
- **Session resumption tracking** — when an `.away` agent's transcript starts updating, it flips back to `.running` automatically, but the timer reflects total elapsed since `started` (including the away gap).

---

## Caveats

- **macOS TCC may prompt for Full Disk Access** the first time the app reads transcripts. Granting helps with AI titles; denying just disables them.
- **Photo Library / Desktop prompts** can fire even though we don't touch them — false positives from macOS being aggressive about unsigned apps. Click *Don't Allow* every time; the app keeps working.
- **AI generation depends on `claude` CLI being authed.** If `claude -p` fails (network, auth), titles silently don't update; check `~/.claude/agent-monitor-debug.log`.
- **Non-Anthropic Claude Code clients are not supported** — the hook payload format and transcript schema are specific to Claude Code.

---

## File reference (for hacking on this)

| Class | Responsibility |
|---|---|
| `AgentMonitorApp` | App entry point; configures floating window via `WindowAccessor` |
| `WindowAccessor` | Bridges SwiftUI to AppKit `NSWindow` to set level/collectionBehavior |
| `AgentStore` | Reads `agents.jsonl`, applies events, runs staleness, holds generators |
| `Agent` | Per-session state struct |
| `AgentEvent` | One line in `agents.jsonl` |
| `TranscriptReader` | Parses Claude's transcript JSONL with mtime-keyed cache |
| `TranscriptInfo` | Output of `TranscriptReader.read` |
| `TitleGenerator` | Persistent title via `claude -p` |
| `LiveStatusGenerator` | Live "doing now" subtitle via `claude -p` |
| `ClaudeP` | Shared `claude -p` runner with env tagging, cwd pinning, stderr capture |
| `ContentView` | Two-column window layout |
| `AgentRow` | One agent's row: status dot, time, status text, subtitle, hover X, context menu |

---

## Quick reference

```bash
# Build and launch
./build.sh

# Force-quit and rebuild
pkill -x AgentMonitor && ./build.sh

# Wipe state (don't do this with active sessions)
: > ~/.claude/agents.jsonl

# View debug log
tail -f ~/.claude/agent-monitor-debug.log

# Check what's in the event log
tail -20 ~/.claude/agents.jsonl | jq -c .

# Test the hook script manually
echo '{"session_id":"test","cwd":"/x","hook_event_name":"SessionStart"}' | ./hooks/agent-monitor-hook.sh
```
