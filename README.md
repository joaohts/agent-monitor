# Agent Monitor

A native macOS floating window that shows live status of every running coding-agent session across your machine — **Claude Code, Codex, and Cursor**, side by side in one list. Status, runtime, AI-generated titles, and live "what's happening now" descriptions. Claude Code and Codex are driven by hooks writing JSON-line events; Cursor is read live from its local SQLite store (no hooks needed). Each row is tagged with its source.

Built with native SwiftUI and a small comms integration module (no Xcode project or Swift Package Manager). The app bundles a pinned standalone comms node release; the node runs independently under the user's service supervisor.

New in this version and upgrade notes: see **[CHANGELOG.md](CHANGELOG.md)**.

## What it does

- **Always-on-top floating window** that lists every Claude Code, Codex, and Cursor session you have open, each tagged with its source
- Live status per session: `running`, `away`, `needs attention`, `idle`, `inactive`
- Per-turn runtime timer that ticks while running and freezes on stop
- AI-generated session titles via a side-car `claude -p` call
- Live "what's happening right now" subtitle while a session is actively processing
- Sound alerts when a session needs your attention or finishes
- **Push notifications to your phone** (optional) via any MCP server exposing a `send_push` tool
- **Stats overlay** with daily / weekly / monthly / all-time tabs: sessions, steps, time totals, per-step averages, concurrency duration, top-3 projects, hour-of-day histogram
- Workspace layout: a collapsible agent sidebar plus tiled per-session report panes (or the original two-column list in Classic view)
- **Live session summaries** (opt-in): a per-session report of what each agent is doing — see [Cost & privacy](#cost--privacy)
- **Floating bubbles overlay** (`⌥⌘B`): an ambient, click-through, always-on-top view that floats over fullscreen apps — one colored bubble per session
- **Jump to a session** (`⌥1`–`⌥9`, `` ⌥` ``): focus the exact Ghostty tab running an agent, from anywhere *(Ghostty only)*
- **Custom + AI-generated tags**: name any agent freeform, or let Haiku tag it (`tag · project #N`)
- **Native macOS notification banners** (optional) on needs-attention / turn-end

See **[docs/features-and-setup.md](docs/features-and-setup.md)** for details on these and how they degrade without Ghostty.

All Claude Code state lives in `~/.claude/agents.jsonl`. Claude Code hooks append events; the app reads and renders. State transitions that aren't fired by hooks (`.away`, `.inactive`, post-permission resume) are detected by transcript-mtime polling and persisted as synthetic events so the log captures the full timeline.

---

## Requirements

- macOS 13+ on Apple Silicon or Intel
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`. Full Xcode is not needed.
- `jq` — `brew install jq`
- `python3` — used for release checksum verification and the per-user comms service install
- At least one logged-in agent CLI: `claude` (Claude Code) or `codex`. When both are present,
  Agent Monitor prefers Claude for local AI labels; Codex is the automatic fallback.
- Source builds need network access to download the pinned public comms release, or
  `COMMS_RELEASE_DIR=/path/to/verified-release-files`

Cursor needs nothing extra: if it is installed, its sessions appear automatically.

---

## Quick install

```bash
git clone https://github.com/joaohts/agent-monitor.git
cd agent-monitor
./install.sh
```

The installer:
- Verifies prereqs (`swiftc`, `jq`, `python3`, and at least one of `claude` / `codex`) and prints install hints if anything required is missing
- **Sets up a stable self-signed code-signing identity** (a dedicated keychain it owns — zero clicks, no login password) so macOS notification + Automation grants persist across rebuilds; idempotent, and `build.sh` falls back to ad-hoc if it's absent
- Builds `AgentMonitor.app` via `build.sh`, installs the bundled comms node, and launches the app
- Smoke-tests the hook script with sample input
- **Idempotent merge** of hook entries into `~/.claude/settings.json` via `jq`:
  - Existing hooks for other tools are preserved (added as additional matchers, not overwritten)
  - Re-running won't duplicate our entries (detects our hook path is already registered)
  - Backup of `settings.json` saved as `settings.json.bak.YYYYMMDD_HHMMSS` before any change
  - If `jq` produces invalid JSON, the original is left untouched and the script exits non-zero
- Registers the equivalent supported lifecycle hooks in `~/.codex/hooks.json`
  when Codex is installed, without requiring Claude or creating Claude configuration
- On Codex-only machines, AI titles, live activity labels, and housekeeping summaries
  run through the logged-in Codex subscription using isolated, ephemeral, read-only calls
- **Ghostty integration wizard** (only if Ghostty is installed): prompts to enable jump-to-tab + agent-monitor-owned tab titles, setting Claude's `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` and/or Codex's `tui.terminal_title=[]` for the installed runtimes, then adding `shell-integration-features = no-title` to Ghostty (all with backups). Skips cleanly when Ghostty is absent.
- Symlinks the app into `~/Applications` so Spotlight finds it
- Prints next-step instructions for TCC prompts (Automation on first jump; Notifications when first enabled)

---

## What install changes

Every path the installer touches, and how each is undone. `./uninstall.sh` reverses
the rows marked **auto**; the rest are listed in its closing message.

| What | Path | Undo |
|---|---|---|
| Claude Code hooks (10 events, see [the hook script](#the-hook-script-agent-monitor-hooksh)) | `~/.claude/settings.json` (backup `settings.json.bak.*`) | **auto** — other tools' hooks preserved |
| Codex hooks (7 events), if Codex is installed | `~/.codex/hooks.json` (backup `hooks.json.bak.*`) | **auto** |
| App build | `AgentMonitor.app` in the repo | **auto** |
| Spotlight symlink | `~/Applications/AgentMonitor.app` | **auto** |
| Signing keychain + its password | `~/Library/Keychains/agent-monitor-signing.keychain-db`, `~/.config/agent-monitor/signing-keychain.pw` | **auto** |
| Event log, debug log, names, Ghostty map | `~/.claude/agents.jsonl`, `~/.claude/agent-monitor-debug.log`, `~/.claude/agent-monitor-names.json`, `~/.claude/agent-monitor-ghostty-map.json` | **auto** (kept with `--keep-data`) |
| Ghostty wizard *(opt-in, Ghostty only)* | `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE` in `~/.claude/settings.json`; `[tui] terminal_title = []` in `~/.codex/config.toml`; `shell-integration-features = no-title` in `~/.config/ghostty/config` | manual — remove the lines, or restore the `.bak.*` copies next to each file |
| Comms CLI | `~/.local/bin/comms` (`comms-v1` when a legacy `comms` exists) | manual — `rm ~/.local/bin/comms` |
| Comms node service | `~/Library/LaunchAgents/com.joaohts.comms.plist` | manual — `launchctl bootout gui/$(id -u)/com.joaohts.comms`, then delete the plist |
| Comms identity, keys and messages | `~/.local/share/comms/` | manual — deleting it loses this machine's identity permanently |
| Comms install metadata | `~/.config/agent-monitor/comms-install.json` | manual — `rm` |
| `open-comms` skills | `~/.claude/skills/open-comms/`, `~/.codex/skills/open-comms/` (`open-comms-v1` when one already existed; a replaced custom skill is backed up under `~/.local/state/comms/skill-backups/`) | manual — `rm -rf` the skill directories |
| `claude` shell alias (only if you have no `claude` alias/function already) | `# BEGIN/END COMMS CLAUDE ALIAS` block in `~/.zshrc` or `~/.bashrc` (backup `.zshrc.comms-backup-*`) | manual — delete the block |

At runtime the app also creates `~/.claude/agent-monitor-summaries/` (only once summaries
are enabled) and `~/.claude/agent-monitor-cursor-dismissed.json`; preferences live in
the `com.local.agentmonitor` UserDefaults domain (`defaults delete com.local.agentmonitor`).

---

## Cost & privacy

- **Live session summaries are opt-in.** The housekeeping agent is off by default; turn it on
  in **Settings → Housekeeping**. When on, it folds each session's new activity through your
  logged-in `claude` / `codex` subscription (or a metered Anthropic API key, if you put one in
  `~/.claude/agent-monitor-api-key` and pick that backend). It is incremental, but it is real usage.
- **Session titles and live "doing now" labels are on by default.** They are short Haiku calls
  through the same logged-in CLI, throttled per session. Turn them off in **Settings → AI**;
  **Classic view** also disables summaries entirely.
- **What it reads:** Claude Code transcripts under `~/.claude/projects/`, Codex rollouts under
  `~/.codex/sessions/`, and Cursor's local SQLite store
  (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, read-only; disable in
  **Settings → Sources**). Excerpts of transcripts are sent to the model only for the AI
  features above.
- **Full Disk Access:** macOS may prompt the first time the app reads transcripts. Denying only
  disables the AI features.
- **Where results go:** summaries are stored locally as JSON in `~/.claude/agent-monitor-summaries/`;
  the optional markdown export goes only to a folder you choose. Nothing is sent to a server
  run by this project.

---

## Uninstall

```bash
./uninstall.sh             # full clean slate
./uninstall.sh --keep-data # preserve agents.jsonl + debug log
```

The default is a complete clean slate:
- Stops the running app
- Removes the `~/Applications/AgentMonitor.app` symlink
- Unregisters our hooks from `~/.claude/settings.json` and `~/.codex/hooks.json` (preserves other tools' hooks; saves a backup first)
- Deletes the `AgentMonitor.app` build artifact in the repo
- Deletes `~/.claude/agents.jsonl`, `~/.claude/agent-monitor-debug.log`, and the names / Ghostty-map files
- Removes the signing keychain and its password file

Not auto-handled (deliberately):
- **The comms node** — CLI, launchd service, identity/keys/history, `open-comms` skills and the
  `claude` shell alias keep running so agent communications aren't interrupted. The uninstaller
  prints the exact commands to remove them; see also [What install changes](#what-install-changes).
- **Ghostty wizard edits** — restore the `.bak.*` copies or remove the lines by hand
- **TCC permissions** (Full Disk Access etc) — revoke manually in System Settings → Privacy & Security
- **`settings.json.bak.*` backups** — kept as safety nets, rm them yourself
- **Summaries** in `~/.claude/agent-monitor-summaries/` and preferences in `com.local.agentmonitor`
- **The repo itself** — `rm -rf` or `git clean` manually

---

## Usage

After `./install.sh`, the app sits in your menu/dock and the floating window stays above other windows.

### Window behavior

- **Main window** is a regular, normal-level window — movable by background, standard traffic-light buttons, lives in its own Space like any app window.
- **Bubbles overlay** is the always-on-top one: a separate non-activating, click-through panel (`canJoinAllSpaces` + `fullScreenAuxiliary`, screen-saver level) that floats over other apps including fullscreen Spaces. Toggle it with the header button or `⌥⌘B`. The two coexist.
- **Spotlight-launchable** — installer symlinks `AgentMonitor.app` into `~/Applications`, so `Cmd+Space → "Agent Monitor"` works
- **Custom dock/Spotlight icon** generated from `assets/icon.png` on every build (auto-padded to square + scaled to all 10 required iconset sizes)

### Header bar

Trimmed to the essentials — everything configurable now lives in the Settings page (⚙️).

| Icon | Function |
|---|---|
| Count badge | Total agents in the list |
| ▦ grid | Toggle the bubbles overlay (`⌥⌘B`) |
| 📊 chart | Toggle the stats overlay |
| ⚙️ gear | Open the **Settings** page |
| ↻ arrow | Force reload from `agents.jsonl` |

### Settings page (⚙️)

A grouped overlay with independent sections:

- **Bubbles** — show overlay · include inactive sessions · corner picker · size
- **Notifications** — sound alerts · macOS banners · push to phone (auto-disabled with a hint when no push server is configured)
- **AI** — toggle AI session-title generation (tags are generated on demand via ✨ when naming an agent)
- **Sources** — monitor Cursor sessions on/off
- **Interface** — Classic view (original list, summaries fully off)
- **Housekeeping** — live session summaries (off by default) · backend · interval · markdown export folder
- **Comms node** — node status, nickname, broker, peers and grants
- **Shortcuts** — reference list; jump shortcuts (`⌥1…9`, `` ⌥` ``) are shown only when Ghostty is detected

### Per-row interaction

- **Hover** — row highlights, X button becomes opaque
- **Click X** — appends a `cleared` event, removes the agent
- **Right-click** — context menu: *Name this agent…* (manual or ✨ AI tag) / *Clear name* / *Dismiss session* / *Copy session ID*

### Statuses

| Status | Color | Column | When | Timer |
|---|---|---|---|---|
| `running` | 🟢 green | right | `UserPromptSubmit` fires; Claude actively processing | live ticking |
| `away` | 🟡 yellow | right | Auto: `.running` transcript silent for >60s | keeps ticking, dimmed |
| `needs attention` | 🟠 orange | left | `Notification` with `notification_type: permission_prompt` | frozen |
| `idle` | 🔵 blue | left | Recently active — freshly opened OR just finished a turn | frozen |
| `inactive` | ⚪ gray | left | Auto: `.idle` for >5 min — abandoned | frozen |

**Sort order within columns:** `needsAttention < running < away < idle < inactive`, then by recency.

The `Stop` hook now maps to `.idle` (not the old `.stopped`). After 5 min of no activity (events OR transcript writes), it auto-decays to `.inactive`. To go back to `.running`, the user just needs to send another prompt (`UserPromptSubmit` resets the timer).

#### Row layout

```
project-name #1                                   ← cwd basename + sibling index
0:42 · running · sonnet-4.6                       ← time · status · model alias
writing Swift app monitor                         ← live status (callout font, white) while running
                                                    ↳ persistent generated title (caption font, gray) when not
```

The third metadata token is the **model** in use, parsed from the most recent assistant entry in the transcript (e.g. `sonnet-4.6`, `opus-4.7`, `haiku-4.5`). Falls back to a session ID prefix for brand-new sessions where no transcript exists yet.

#### Status transitions

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

### Stats overlay

Click the 📊 chart icon in the header to overlay a stats sheet on top of the agents view. Tabs at top switch between four time windows:

- **Daily** — local midnight today to now (uses `Calendar.current`, so timezone follows macOS)
- **Weekly** — past 7 days
- **Monthly** — past 30 days
- **All time** — since the beginning of `agents.jsonl`

#### Metrics

| Section | Metric | Notes |
|---|---|---|
| Activity | Sessions created | Count of `idle` (SessionStart) events in window |
| | Steps (turns) | Count of `started` (UserPromptSubmit) events in window |
| Time totals | Running | Total seconds in `.running` |
| | Away | Total seconds in `.away` |
| | Needs attention | Total seconds in `.needsAttention` (excludes post-permission resume) |
| Per-step averages | Running / step | Total running / step count |
| | Away / step | Total away / step count |
| | Needs-att / step | Total needs-attention / step count |
| Top projects (running) | Top 3 cwds | Sorted by running time, basename only |
| Concurrency (running) | Max concurrent | Peak number of sessions in `.running` simultaneously |
| | Time at ≥1..≥5 | Total seconds with that many or more `.running` sessions |
| Hour-of-day histogram | 24 buckets | Running time bucketed by local hour-of-day, normalized to max |

#### How it computes

A single chronological pass over all events in `agents.jsonl` produces all four windows simultaneously. Per-session state machine tracks transitions; running interval distribution into hour buckets is done at the same time. Live tail handling means in-progress states keep accumulating up to `Date()` — totals grow second-by-second as a session runs.

The 1Hz polling timer that already exists for `.running`/`.away`/`.needsAttention`/`.idle` agents triggers `reload()`, which re-runs the stats compute. So the overlay is always live, no refresh button needed.

**Old-data caveat**: sessions that ran *before* this build don't have synthetic `away_start` / `needs_attention_end` / `inactive_start` events in the log, so:
- Time between `needs_attention` and `stopped` is fully attributed to needs-attention (under-counts running for permission turns)
- Quiet stretches during running are attributed to running (over-counts running for long turns)

The two errors partially offset. New sessions going forward have the full event log and produce accurate breakdowns.

### Multiple tools: Claude Code + Codex + Cursor

Agent Monitor is **multi-source**. Every tool plugs in behind one `SessionProvider`
protocol and is merged into the same `Agent` list — so the window, bubbles, stats,
and notifications all work identically regardless of which tool a session belongs to.
Each row carries a small **source tag** (`Claude` / `Cursor`) so you can tell them apart.

#### Claude Code (built-in, hook-driven)

The original path: hooks append events to `~/.claude/agents.jsonl`, the app reads
transcripts for titles and live status. Nothing about this changed.

#### Codex (hook-driven)

Codex uses the same event/state pipeline as Claude Code. Global lifecycle hooks
report session start/end, prompts, permission waits, turn completion, subagents,
the transcript path, and the controlling TTY. Codex rollout transcripts under
`~/.codex/sessions/` supply task text and model metadata for titles and summaries.
Because Codex events land in the shared event log, its sessions contribute to the
same activity statistics. In the bubble overlay, Claude and Codex use orange and
blue right-edge stripes respectively; Cursor uses a dashed ring.

Codex token-count events also supply live context-window and account rate-limit
usage. These appear in the main session row and bubble tooltip without widening
the bubble. The Stats overlay can filter activity to All, Claude, or Codex and
shows detailed live Codex totals for input, cached input, output, reasoning,
context fill, rate-window usage, and reset time.

#### Cursor (read-only, polled)

Cursor has **no hooks**, so its state is reconstructed by reading Cursor's own global
SQLite store directly:

- **Storage:** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`,
  opened `READONLY` (Cursor is the only writer; WAL mode lets us read committed state
  live). The app **never writes** to it — every access is best-effort, so a missing
  install or a schema shift just degrades to an empty list instead of crashing.
- **Liveness:** the WAL sidecar (`state.vscdb-wal`) is kqueue-watched — its mtime
  advances on every Cursor write — plus a slow 30s heartbeat for time-based decay
  (`idle → inactive`) that has no write to ride on.
- **Cheap reads:** rows render from the lightweight `composer.composerHeaders` index;
  the multi-hundred-MB blob table is never touched on the hot path. Generating state
  is read with `json_extract` for only the few recently-touched composers.
- **Status derivation** (no hooks, so inferred from the store):

  | Status | When |
  |---|---|
  | `running` | composer is generating and the store was touched recently |
  | `away` | generating but silent past the away cutoff |
  | `needs attention` | `hasBlockingPendingActions` (waiting on you) |
  | `idle` | finished and recently active |
  | `inactive` | finished and silent past the inactive cutoff |

- **Recency window:** Cursor keeps every composer forever, so only sessions touched in
  the **last 12 hours** are surfaced (anything active is recent by definition).
- **Subagents:** Cursor's "explore"/task sub-composers are linked to their parent and
  shown with their own row + agent-type label, mirroring Claude subagents.
- **Dismiss:** per-row hide is persisted to
  `~/.claude/agent-monitor-cursor-dismissed.json`; a row reappears when its composer is
  touched again (just like a Claude session reappearing on a new event).

**No setup for Cursor** — if Cursor is installed, its sessions appear automatically.
Nothing to register, no `settings.json` changes. If Cursor isn't installed, the
provider reports unavailable and is skipped.

> **Adding another tool (Zed, Windsurf, …):** add an `AgentSource` case, implement a
> `SessionProvider` that reads that tool's storage and derives `[Agent]`, and register
> it in `AgentStore`. The view layer, stats, bubbles, and notifications need no changes.

---

## Optional integrations

### Local agent communications

Every installation includes local comms for Claude and supported Codex sessions.
The Comms dashboard reads node presence, persistent identities, and message history;
Settings manages the machine nickname, optional broker, pinned peer keys, and
directional messaging/history grants. Local communication needs no broker account.

- Claude's node settings select a 30-minute Monitor (default) or experimental MCP channel. The `claude` shortcut follows the saved mode on the next launch/resume, supplying MCP configuration and the development-channel flag only in channel mode. Existing sessions keep their current receiver.
- Codex requires its supported app-server tool-output receiver; the GUI never types
  peer text as a user message. Unsupported sessions show the required setup.
- Closing, freezing, or rebuilding the viewer does not stop the node or its receivers.
- Existing legacy commands, credentials, and history remain separate during migration.

See [node setup and migration](docs/comms-connection.md) for release acquisition,
installation paths, pairing, updates, rollback, and a direct independence test.

### Part of a three-repo stack

| Repo | What it is | Runs on |
|---|---|---|
| [brain](https://github.com/joaohts/brain) | A long-running personal agent: LLM loop, tools, memory, and channels (WhatsApp, comms, CLI) | Linux / Raspberry Pi |
| [comms](https://github.com/joaohts/comms) | Encrypted messaging between agent sessions and machines: node, CLI, optional broker | macOS, Linux |
| **agent-monitor** (this repo) | macOS app: live view of every Claude Code / Codex / Cursor session, plus a comms dashboard | macOS |

Each works alone. Together: install **comms** on every machine, **agent-monitor**
on your Mac (it bundles a pinned comms release), and **brain** on an always-on box
with its comms channel enabled. Pair the machines once and every session — and the
brain — can reach every other.

How the parts connect:

- **agent-monitor ↔ comms** — the app bundles a pinned comms release, installs it as a per-user service, and shows its agents, history, pairing and grants. See [agent-monitor: comms connection](https://github.com/joaohts/agent-monitor/blob/main/docs/comms-connection.md).
- **brain ↔ comms** — the brain joins comms as a persistent agent (alias `brain`), so any session can message it and it can message back. See [comms: brain integration](https://github.com/joaohts/comms/blob/main/docs/BRAIN.md).
- **Claude Code / Codex ↔ comms** — sessions launched through `comms claude` / `comms codex` receive peer messages. See [comms: Claude](https://github.com/joaohts/comms/blob/main/docs/CLAUDE.md) and [Codex](https://github.com/joaohts/comms/blob/main/docs/CODEX.md).

### Ghostty

With [Ghostty](https://ghostty.org), Agent Monitor can jump to the exact tab running a
session (`⌥1`–`⌥9`, `` ⌥` ``) and own tab titles. `./install.sh` offers this as an opt-in
wizard; without Ghostty every other feature works. See
[docs/features-and-setup.md](docs/features-and-setup.md) for the portability tiers.

### Push notifications (optional)

The 🔔 bell button in the header sends pushes to your phone through an **HTTP MCP server that exposes a `send_push` tool** (see [Wire format](#wire-format)) when:

- A session transitions to **`.needsAttention`** → urgent push: `🟠 <project> needs attention`
- A session transitions to **`.idle`** from `running` / `away` / `needs_attention` (real turn completion) → info push: `✅ <project> finished`

Skipped: brand-new sessions (`nil → idle`), automatic decay (`idle → inactive`), all other transitions.

#### Configuration

The app reads the push server from `~/.claude.json` at launch: the `mcpServers` entry named `push` by default. Point it at your own server:

```json
{
  "mcpServers": {
    "push": {
      "type": "http",
      "url": "https://your-push-server.example/mcp",
      "headers": {
        "Authorization": "Bearer <YOUR_TOKEN>"
      }
    }
  }
}
```

If your server already has another name in `~/.claude.json`, point the app at it instead:

```bash
defaults write com.local.agentmonitor agentMonitor.pushServer YOUR_SERVER_NAME
```

Without a push server the bell stays disabled and everything else works.

#### Button states

- **Configured + on** — `bell.badge.fill` in accent color, sending pushes
- **Configured + off** — outline `bell` in secondary color, dormant
- **Not configured** — grayed out + disabled, tooltip explains how to enable

The on/off toggle is persisted to `UserDefaults` so it survives app restarts. The config itself is read once at app launch, so if you edit `~/.claude.json` you must restart the app:

```bash
pkill -x AgentMonitor && open ~/Applications/AgentMonitor.app
```

#### Wire format

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

## Architecture and internals

```
┌─ Claude Code (any session, any project) ─┐
│   SessionStart, UserPromptSubmit, Stop,   │     hooks fire
│   Notification, PermissionRequest, …      │ ───────────────► hook script
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

### The hook script (`agent-monitor-hook.sh`)

A single bash script registered for 10 Claude Code hooks (and 7 Codex hooks — the same names minus `Notification`, `Elicitation` and `StopFailure`). Designed to never block or fail Claude Code.

| Claude hook | Mapped event | Notes |
|---|---|---|
| `SessionStart` | `idle` | Session opened, no prompt yet |
| `UserPromptSubmit` | `started` | New run begins; resets the timer |
| `Notification` (`permission_prompt`) | `needs_attention` | Real attention needed |
| `Notification` (`idle_prompt`) | *(skipped)* | The 60s "Claude is waiting for your input" nudge — ignored |
| `PermissionRequest` | `needs_attention` | Permission dialog shown (modern path) |
| `Elicitation` | `needs_attention` | An MCP server is asking you for input |
| `Stop` | `stopped` | Turn finished |
| `StopFailure` | `api_error` | Turn ended on an API error (overloaded, rate limit, …); shown in red |
| `SessionEnd` | `cleared` | Removes from list |
| `SubagentStart` / `SubagentStop` | `started` / `stopped` | Keyed by `agent_id` so each subagent gets its own row under its parent |

#### Skip conditions (the script exits 0 silently)

1. `AGENT_MONITOR_INTERNAL=1` env var set (our own subprocess)
2. Empty stdin
3. Missing `session_id` or `hook_event_name` in the input
4. `notification_type == idle_prompt` (idle nudge, not real attention)
5. Unknown hook name

#### Event format

```json
{"event":"started","session_id":"abc12345","cwd":"/path/to/proj","ts":"2026-04-28T03:42:01Z","message":"user prompt","transcript_path":"/Users/.../session_id.jsonl"}
```

#### Synthetic events (emitted by the app, not the hook)

To make the event log a complete state-transition timeline, the app writes synthetic events back into `agents.jsonl` whenever it detects a transition that no hook fires for:

| Event | When | Why |
|---|---|---|
| `away_start` | `.running` transcript silent for >60s | Captures `.running → .away` transition |
| `away_end` | `.away` transcript writes resume | Captures `.away → .running` resumption |
| `needs_attention_end` | `.needsAttention` transcript writes resume (>1s after the event) | Captures post-permission resume (no Claude hook fires for this) |
| `inactive_start` | `.idle` with no activity for >5 min | Captures abandonment |

These are required for accurate stats — without them, time spent in away/needs-attention vs running can't be cleanly split.

### The AI features

Two independent generators that both shell out to `claude -p --model claude-haiku-4-5` (or the logged-in `codex` CLI on Codex-only machines). Both gated by the AI toggle in Settings.

The third AI feature, **live session summaries** (the housekeeping agent), is opt-in and documented in [docs/housekeeping-agent.md](docs/housekeeping-agent.md).

#### 1. Persistent title (`TitleGenerator`)

**Triggers:** at 3 user messages, then every +20.

**Excerpt sent:** first 2 turns + last 6 turns (capped at 600 chars each), plus latest auto-summary if present (capped at 1200 chars).

**Prompt:**
> Below is excerpts from a Claude Code session. Generate a concise 5-7 word title summarizing what this session is about. Output ONLY the title — no quotes, no trailing punctuation, no preamble.

**Display:** shows in the row's **subtitle** (caption font, gray) when status is *not* running. Persists across status changes.

#### 2. Live status (`LiveStatusGenerator`)

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

#### Subprocess hygiene

Every `claude -p` call from the app:
- Sets env `AGENT_MONITOR_INTERNAL=1` — the hook script exits early when it sees this, so the side-car subprocess doesn't appear in the monitor as its own session
- Pins `cwd` to `/tmp` — prevents inheriting a TCC-protected directory (Desktop/Documents/Downloads) and triggering cascading permission prompts
- Captures stderr to `~/.claude/agent-monitor-debug.log` for diagnostics

#### Output sanitization

Both generators run output through `ClaudeP.sanitizeShortPhrase`:
- Trim whitespace and newlines
- Take only the first line
- Strip wrapping quotes (`"`, `'`, `` ` ``)
- Strip trailing `.`, `!`, `?`, `…`

### Smart features and edge cases

#### Concurrent multi-session writes

All sessions write to one global `~/.claude/agents.jsonl`. POSIX atomic-append under `O_APPEND` guarantees no interleaving for lines under 4KB.

#### Sibling indexing

Multiple sessions with the same `cwd` show as `project-name #1`, `project-name #2`, ordered by `firstSeen`. The base name is the cwd's last path component.

#### Idle prompt filtering

Claude's `Notification` hook fires both for permission prompts (real attention) and the 60-second "waiting for your input" nudge. The hook script reads `notification_type` and skips `idle_prompt` so the row doesn't flicker into needs_attention every minute.

#### `.away` detection (transcript polling)

- Watches the per-session transcript file's mtime
- If silent for >60s AND the run has been going for >60s, mark `.away`
- Anchored against `runStartedAt` so freshly-started runs don't immediately appear away (the previous turn's mtime no longer counts)
- If activity resumes (transcript writes), automatically flips back to `.running` on next reload
- Never auto-transitions to `.stopped` — only a real `Stop` event does that

This is a heuristic. Limitations:
- Long thinking pauses (>60s before first token) will trigger `.away` briefly
- Long tool executions don't trigger `.away` (we check `tool_use` IDs and skip if any are unmatched)
- Truly interrupted sessions never go to `.stopped` — they sit at `.away` forever (use the X button to dismiss)

#### Periodic reload

When any agent is `.running`, a 1Hz `Timer` calls `reload()` so the staleness check and live-status generation re-evaluate even when no new events arrive.

#### Title/excerpt caching

`TranscriptReader` caches parsed transcript info keyed by file mtime. Re-reads only when the file actually changes, so reloads are fast even with many sessions.

### Tunable constants (in `AgentMonitor.swift`)

```swift
// AgentStore
static let awayThresholdSec: TimeInterval = 60      // .running → .away
static let inactiveThresholdSec: TimeInterval = 300 // .idle → .inactive (5 min)
static let staleCheckInterval: TimeInterval = 1     // periodic reload while running/away/needsAttention/idle

// LiveStatusGenerator
static let minRunSeconds: TimeInterval = 5          // gate live status until run is ≥5s
static let minIntervalSeconds: TimeInterval = 60    // throttle: ≥60s between calls per session

// TranscriptReader
static let headTurns          = 2                   // title: first N turns
static let tailTurns          = 6                   // title: last N turns
static let liveUserMessages   = 5                   // live status: last N user msgs + their assistant turns
static let perTurnCharCap     = 600                 // truncate each turn's text
static let summaryCharCap     = 1200                // truncate auto-summary if huge
```

### What's NOT implemented (deliberate choices)

- **Instant interrupt detection** — no clean way without Anthropic adding an Interrupt hook. The `.away` heuristic is the best we can do externally.
- **Window position persistence** — opens at the same place each launch.
- **Notarization / distribution signing** — local personal app. `install.sh` *does* create a self-signed code-signing identity (so macOS notification + Automation grants persist across rebuilds; `build.sh` falls back to ad-hoc if absent), but the app isn't notarized for distribution to others.
- **Log rotation** — `agents.jsonl` grows forever. Manual: `: > ~/.claude/agents.jsonl` to truncate.
- **Session resumption tracking** — when an `.away` agent's transcript starts updating, it flips back to `.running` automatically, but the timer reflects total elapsed since `started` (including the away gap).

### Caveats

- **macOS TCC may prompt for Full Disk Access** the first time the app reads transcripts. Granting helps with AI titles; denying just disables them.
- **Photo Library / Desktop prompts** can fire even though we don't touch them — false positives from macOS being aggressive about locally-signed apps. Click *Don't Allow* every time; the app keeps working.
- **AI generation depends on `claude` CLI being authed.** If `claude -p` fails (network, auth), titles silently don't update; check `~/.claude/agent-monitor-debug.log`.
- **Non-Anthropic Claude Code clients are not supported** — the hook payload format and transcript schema are specific to Claude Code.
- **Cursor is read live from its local SQLite store** (`state.vscdb`), opened read-only. The app never writes to it, but the schema is Cursor's own and undocumented — a future Cursor update could shift it, in which case Cursor rows degrade to empty rather than break the rest of the app. Cursor sessions are surfaced only for the last 12 hours of activity, and per-row dismiss (not hooks) controls visibility.

---

## Development

### Manual install

If you'd rather do it by hand:

```bash
cd /path/to/agent-monitor
./build.sh           # compiles + launches AgentMonitor.app
```

The app installs the bundled comms node on first launch if needed.

Then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":     [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "Notification":     [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "Elicitation":      [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "Stop":             [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "StopFailure":      [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "SessionEnd":       [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "SubagentStart":    [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}],
    "SubagentStop":     [{"hooks": [{"type": "command", "command": "/absolute/path/to/agent-monitor/hooks/agent-monitor-hook.sh"}]}]
  }
}
```

The first time you trigger an AI title (or live status), macOS may prompt for **Full Disk Access** (because the app reads transcripts in `~/.claude/projects/`, written by another signed app). Grant or deny — denying just disables AI titles, everything else still works.

### Build modes

```bash
./build.sh           # debug build (~3s, recommended for iteration)
RELEASE=1 ./build.sh # optimized build (~15s)
NO_LAUNCH=1 ./build.sh # verify without closing/launching the current GUI
```

---

## File reference

### Files involved

| Path | Purpose |
|---|---|
| `AgentMonitor.swift` | Main SwiftUI viewer, activity providers, hooks, and session navigation |
| `CommsNodeClient.swift` | Bounded local CLI/API client and observational event stream |
| `CommsNodeViews.swift` | Node status, identities, history, pairing, and directional grants |
| `comms-release.json` | Pinned comms release, API version, and archive checksums |
| `build.sh` | Compiles to `.app` bundle, kills prior instance, launches |
| `hooks/agent-monitor-hook.sh` | The Claude Code hook script |
| `~/.claude/agents.jsonl` | Event log (the database) |
| `~/.claude/settings.json` | Where the hooks are registered globally |
| `~/.claude/projects/*/*.jsonl` | Claude's own per-session transcripts (we read for titles) |
| `~/.claude/agent-monitor-debug.log` | Hook + `claude -p` debug output |
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | Cursor's SQLite store (read-only; source for Cursor rows) |
| `~/.claude/agent-monitor-cursor-dismissed.json` | Persisted per-row dismiss state for Cursor sessions |

### Classes (for hacking on this)

| Class | Responsibility |
|---|---|
| `AgentMonitorApp` | App entry point; configures floating window via `WindowAccessor` |
| `WindowAccessor` | Bridges SwiftUI to AppKit `NSWindow` to set level/collectionBehavior |
| `AgentStore` | Reads `agents.jsonl`, applies events, runs staleness, holds generators; owns the `SessionProvider` registry and merges every source into one list |
| `SessionProvider` | Protocol every non-Claude tool conforms to (currentAgents / focus / dismiss / housekeeping) |
| `CursorReader` | Read-only SQLite access to Cursor's `state.vscdb` (headers + generating state) |
| `CursorProvider` | `SessionProvider` for Cursor: WAL-watched polling → `Agent`/`AgentStatus` |
| `Agent` | Per-session state struct |
| `AgentEvent` | One line in `agents.jsonl` |
| `TranscriptReader` | Parses Claude's transcript JSONL with mtime-keyed cache |
| `TranscriptInfo` | Output of `TranscriptReader.read` |
| `TitleGenerator` | Persistent title via `claude -p` |
| `LiveStatusGenerator` | Live "doing now" subtitle via `claude -p` |
| `ClaudeP` | Shared `claude -p` runner with env tagging, cwd pinning, stderr capture |
| `ContentView` | Two-column window layout |
| `AgentRow` | One agent's row: status dot, time, status text, subtitle, hover X, context menu |

### Quick reference

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
