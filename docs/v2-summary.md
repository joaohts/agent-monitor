# Agent Monitor v2 — build summary (handoff)

Branch `feat/housekeeping-agent` (pushed, not merged). Everything is in the single
`AgentMonitor.swift` (~4100 lines). Design rationale: `docs/housekeeping-agent.md`.
User-facing: README "v2" section.

## What shipped

**Housekeeping agent** — a side-car that keeps a live, self-updating report per Claude
Code session by folding only the new transcript delta on each trigger. Three pieces:

1. **`HousekeepingDelta`** — projects a transcript slice (from a byte cursor) into compact
   `U:/A:/T:` lines; drops tool-result bodies / thinking / `isMeta`; each `tool_use` →
   `Tool(keyArg)`.
2. **Fold** — `HousekeepingState` (persisted) / `HousekeepingFold` (model return) /
   `FoldPrompt` (shared prompt) / `HousekeepingProvider` with `ClaudePProvider`
   (subscription `claude -p`) and `HaikuAPIProvider` (metered key, structured output).
   `auto` picks by `ANTHROPIC_API_KEY`. Model: `claude-haiku-4-5`.
3. **`HousekeepingGenerator`** — per-session state + byte cursor, triggers, fold, persist.
   Mirrors `TitleGenerator`/`LiveStatusGenerator`. Wired in `AgentStore.enrichWithTranscripts`.

**Summary = three levels:** `title` (PR-style, sticky — only changes on a focus shift),
`subtitle` (live phase line), `summary` (cumulative, **Markdown**, bullet- and timely-first
under `## Now`/`## Recently`/`## Background`). Plus append-only ledgers: features / fixes /
decisions / sources / projects (project-tagged, strict inclusion tests, dedup).

**Triggers:** fold only once the *assistant* has produced new work (an `A:`/`T:` line) —
never on a lone user message. Effective: Stop (answer), long-turn heartbeat (~2 min),
permission, manual. Depth-1 coalescing per session (mid-fold trigger flushed once on
finish). `size > cursor` gate makes "nothing changed → nothing runs" cheap.

**Frontend (workspace):** main window = collapsible right `AgentSidebar` + tiling
`PaneWorkspace` of `ReportView` panes (click-to-replace focused pane, drag-to-split,
auto-tile to 4 then scroll), near-fullscreen. `ReportView`: single orange accent,
title/subtitle/markdown summary (custom `MarkdownText` renderer), **collapsible ledger
sections (collapsed by default)** with counts, an orange "generating…" ring + spinner
while folding. Font scaling (`store.reportFontScale`, `⌘=`/`⌘−`/`⌘0`, persisted).

**Classic view** — header + Settings → Interface toggle: original two-column live list,
and **disables the summary agent entirely** (generator `enabled` returns false → no folds,
no tokens).

## Data / settings

- JSON state (source of truth): `~/.claude/agent-monitor-summaries/<session>.json`,
  written every fold.
- Markdown export (optional, throttled to turn boundaries): folder picked in Settings →
  Housekeeping. Currently set to `~/notes/jonathan/agent-monitor/`.
- UserDefaults keys: `agentMonitor.housekeeping{Enabled,Provider,HeartbeatSec,MarkdownDir}`,
  `agentMonitor.classicView`, `agentMonitor.reportFontScale`.

## Upgrade impact

Drop-in: only `AgentMonitor.swift` changed — no hook / `settings.json` / dependency /
`build.sh` changes. No new hard requirements. **Summaries auto-run after upgrade**
(subscription/token use); Classic view is the opt-out.

## Open / next

- Push done; PR not opened; not merged to `main`.
- Haiku API backend (`HaikuAPIProvider`) written but never run live (no key on this Mac).
- Markdown export path written but not yet exercised against the vault folder.
- Possible follow-ups: surface title/subtitle in sidebar rows; "expand all" for sections;
  lenient JSON decode on the `claude -p` path (a malformed ledger entry drops a fold);
  host label mapping (personal/work vs raw hostname); inter-agent comms board (idea #2).
