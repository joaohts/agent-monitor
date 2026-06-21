# Housekeeping Agent — Design

A side-car that maintains a slow-growing **working summary** + **quick facts** per
Claude Code session, by folding each step's activity into a bounded running state
instead of re-reading the whole transcript.

Status: **built** on `feat/housekeeping-agent` (projector → fold/provider → side-car →
settings + dashboard), validated live. Decisions below are settled unless under "Open".

---

## Goal

For every watched session, keep:
- a **working summary** that grows much slower than the session itself, and
- **quick facts** — sources used, projects touched, features implemented, fixes made.

Token efficiency is a first-class constraint: this fires on every step, so each
update must cost ~O(summary + delta), never O(whole session).

---

## Settled decisions

### 1. Incremental fold model
Each update sends `system + current summary + current facts + delta` and returns an
updated summary + new facts. The delta is only the new activity since the last fold —
never the full transcript. This is what keeps the summary growing slower than the
session.

### 2. Summary vs facts — rewrite vs append
- **Rewrite each fold** (bounded, can't bloat): `summary`, `status` (current one-line state).
- **Append-only ledgers** (model emits only *new* entries; app merges + dedupes):
  features, fixes, decisions, sources, projects.
- Rationale: rewriting the summary bounds it; append-only ledgers mean the model
  can't accidentally drop old entries and output stays near-empty on quiet turns.

Schema:
```jsonc
{
  "summary": "≤ ~120 words",   // rewrite each fold
  "status":  "one line",        // rewrite each fold

  // global sets (dedupe by exact string)
  "projects":  [],  // repo/dir level
  "sources":   [],

  // project-tagged, append-only (model dedupes prose against existing)
  "features":  [{ "project": "agent-monitor", "text": "..." }],
  "fixes":     [{ "project": "...", "text": "..." }],
  "decisions": [{ "project": "...", "text": "..." }]
}
```
Features/fixes/decisions carry their `project` (a session can touch several — see
multi-repo below). The UI can group by project at display time. Dedup key is
`(project, text)`.

Ledgers are kept in full (no cap) — discipline comes from tight **inclusion tests**,
not a size limit. The exclusions do the work:
- **features** — a capability that now exists and didn't before. *Not* refactors,
  steps toward one, or "improved X." One entry per shipped capability.
- **fixes** — a specific wrong behavior made right. *Not* refactors / cleanups.
- **decisions** — a choice between alternatives that constrains future work
  (architecture, "use X not Y"). *Not* trivial / mechanical picks.
- **sources** — an external doc/URL actually consulted (WebFetch/WebSearch domain,
  key reference).
- **projects** — repo/dir touched.

Dedup: `projects` / `sources` by exact string; `features` / `fixes` / `decisions` are
prose, so the model dedupes against the existing list (passed in on each fold), keyed
by `(project, text)`.

The inclusion tests live in the fold prompt as rule + positive/negative examples, and
are tuned over time (add a negative example whenever junk shows up). Guiding principle:
**when in doubt, leave it out** — a missed entry is cheap, a junk entry is permanent.
A "multi-repo session": one `session_id` whose tool actions touch file paths resolving
to more than one repo root (each path walked up to its nearest `.git`).

### 3. Triggers (all feed one fold path)
- **Stop** — turn boundary. Always.
- **Permission / notification** — intra-turn checkpoint; good "a step happened" proxy
  for long (up to ~10 min) turns. Fires only on normal-permission sessions.
- **Long-turn heartbeat** — fallback (~2 min of continuous activity), so intra-turn
  updates still happen under `bypassPermissions` where no permission ever fires.
  Tunable / optional.
- **Manual** — a button on each session row in the floating window; fires a fold for
  that session immediately. On-demand snapshot; lets the heartbeat run slower (or off)
  to save tokens.

Heartbeat fires only while the session is *running* (idle sessions never heartbeat),
~2 min of continuous activity; tunable in settings.

Delta model handles all of them for free: track "last folded position", fold whatever
is new on any trigger. Permission/heartbeat fold work-so-far; Stop folds the remainder.

### 4. Pluggable backend (`HousekeepingProvider`)
Two implementations, chosen by situation:
- **ClaudeP** — shells out via the existing runner. Uses the personal subscription
  (flat-rate), so its harness overhead costs *latency, not money*. No API key.
- **HaikuAPI** — direct Haiku 4.5 API call. Metered key → minimize tokens; enforces
  the output schema (structured outputs).
- Default by availability: `ANTHROPIC_API_KEY` set → Haiku, else `claude -p`.
  Overridable via setting `housekeepingProvider: auto | claudeP | haikuApi`.
- Both return the same parsed struct; the `claude -p` path prompts for JSON + parses
  defensively.
- **Model:** `claude-haiku-4-5` on both paths — thinking off (the fold is mechanical
  extraction), structured output on the API path. `claude -p` is pinned to Haiku too
  (`--model claude-haiku-4-5`) so both backends are fast and behaviorally comparable;
  a summary fold doesn't need Opus.

### 5. Delta extraction
- Housekeeping keeps its **own transcript byte-offset cursor**, independent of the live
  reader (which trims the middle of `turns` to bound memory). Reuses the incremental
  line-parse, different projection.
- Projection = compact event lines:
  - `U:` user text (cap ~500 chars)
  - `A:` assistant text (cap ~1–2k chars)
  - `T: tool(keyarg)` per `tool_use` — **result bodies dropped**, optional `✗` on error
  - drop: `tool_result` bodies, thinking blocks, `isMeta` lines
- Per-tool key-arg (the raw material for ledgers):
  - Edit / Write / Read / NotebookEdit → file basename → *projects touched*
  - Bash → command (first ~60 chars) → *fixes / actions*
  - Grep / Glob → pattern
  - WebFetch / WebSearch → domain / query → *sources used*
  - Task → subagent description
  - else → tool name only
- A huge multi-tool turn collapses to ~N short lines + prose, blobs gone; a few hundred
  to ~1–2k tokens regardless of real turn size.
- Requires a small `ingestLine` extension: capture `tool_use` actions (currently discarded).

### 6. Plumbing
- The hook stays dumb (writes the event, exits fast — unchanged).
- The app sees the trigger, reads the delta, enqueues a fold job.
- One job in-flight per session; coalesce bursts; runs async; never blocks the session.
- It's a third side-car alongside `TitleGenerator` / `LiveStatusGenerator`.

### 7. Persistence

Two outputs, two configs (the fold needs lossless JSON round-trip; Obsidian wants
markdown — so they're separate):

- **JSON state — source of truth.** One file per session, written every fold
  (cheap, local). Config `summaryStateDir`, default `~/.claude/agent-monitor-summaries/`.
  The fold reads it in and writes it back; the UI and the future comms board render
  from it.
- **Markdown export — derived, optional.** Config `summaryMarkdownDir`, unset by
  default; point it at the synced vault (e.g. `~/notes/jonathan/claude-sessions/`).
  Generated from the JSON; **the fold never parses it back.** Throttled to `Stop` /
  `SessionEnd` (not every intra-turn fold) so the vault's git auto-sync isn't spammed
  with churn.

**No cross-machine conflict by construction.** `session_id` is a UUID → globally
unique, so two Macs writing to the same synced folder never collide; each writes only
its own per-session files and git merges cleanly. **Never** write a shared aggregate /
index file (that *would* conflict). The ID is not needed for safety — only host /
project / date in the filename + frontmatter, for a navigable vault:

- Filename: `<date>-<host>-<project>-<short-sid>.md`
  — e.g. `2026-06-21-personal-agent-monitor-9f3a2b.md`
- Frontmatter:
  ```yaml
  session_id: <full uuid>
  host: personal        # personal | work, from hostname
  projects: [agent-monitor]
  cwd: /Users/joaohts/fun/agent-monitor
  branch: feat/housekeeping-agent   # app-captured (git rev-parse in cwd), not model-emitted
  started: <iso>
  updated: <iso>
  ```
  `branch` is metadata the app reads from the session's `cwd` (not a fold output) —
  it's a per-session field the v2 "Contexto amplo" dashboard wants (projeto · branch ·
  último resumo · status).
  (`short-sid` = first 6 of the UUID, just to keep same-day/same-project files
  distinct in a listing.)

---

## Open decisions

Settle while building, by eyeballing real output (not in the abstract):
- **Per-tool key-arg list / caps** — final tuning against real transcripts.
- **Prompt design** — the fold instruction (incl. inclusion-test examples).

(Bounds settled: summary ≤ ~120 words; ledgers kept in full, no cap/rollover.)

---

## Frontend v2 — workspace layout (in progress)

Pivot from the compact window to an IDE-style full-screen workspace. Unifies the live
list and the summaries dashboard into one screen.

- **Near-fullscreen by default** on launch; sidebar visible; main shows the
  most-recently-active agent.
- **Right sidebar (collapsible)** — the full agent list, active + inactive merged into
  one column, keeping all current row features (status, live status, title, tags,
  Ghostty jump). Toggle to hide → panes take full width.
- **Main area = tiling pane manager.** Each pane is a full `ReportView` of one agent
  (summary · status · branch · fully-expanded ledgers · metadata · live activity).
  - **Click** a sidebar agent → replaces the **focused** pane (or creates the first
    pane when none).
  - **Drag** a sidebar agent into the main area → **splits** (adds a pane).
  - Auto-tile up to **4** panes (1 → full, 2 → side by side, 3–4 → 2×2); beyond 4 →
    scroll. Per-pane close button.
- **Grid tiling, not recursive splits** for v1 (recursive H/V split trees are a SwiftUI
  rabbit hole; revisit only if genuinely missed).
- The `SummaryCard` grows into the pane `ReportView`; the two-column `ContentView`
  content is absorbed into the sidebar; the live/dashboard mode toggle is removed.

## Visualization (downstream)

This agent is the **data layer** for the v2 "Contexto amplo" / orchestration view
(`~/notes/jonathan/projects/agent-monitor-v2.md`). The per-session JSON state is what
that dashboard renders.

Surface split (the groundwork already exists in the code):
- **Bubbles overlay** (`BubblesView` on the click-through `OverlayPanel`) = the ambient
  quick-glance. Stays as-is.
- **Main window** (`ContentView` on a normal resizable `NSWindow`) → grows into the
  **dashboard**: per-agent cards showing summary + status + quick-facts, selectable
  subset (filter by tag/project), live updates as folds land. Already a normal
  resizable window — this is a `ContentView` evolution, not a re-plumb. Add
  `collectionBehavior = [.fullScreenPrimary]` to enable native fullscreen / second
  display.

Built *after* the data layer (steps 2–3) — the dashboard just watches `summaryStateDir`
(kqueue, same pattern used elsewhere) and loads each session's JSON into a published
store the cards observe.

## Build order (proposed)

1. **Delta extractor** — ✅ `HousekeepingDelta` projector (own cursor, U/A/T lines).
2. **Provider** — ✅ `HousekeepingProvider` + `ClaudeP`/`Haiku` impls + fold prompt.
3. **Side-car + persistence** — ✅ `HousekeepingGenerator`: per-session state/cursor,
   triggers wired in `enrichWithTranscripts` (Stop/permission/heartbeat), JSON + markdown
   export, git branch + metadata. Validated live against a real session.
4. **Dashboard** (next) — main window → cards reading the JSON state; manual fold button;
   settings toggle for enable/provider/paths.

Rough size: ~500–700 lines net in the single Swift file; no new deps, no threading
risk (another async side-car). Cost is breadth, not difficulty.
