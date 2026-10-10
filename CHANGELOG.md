# Changelog

Notable user-facing changes to Agent Monitor. Newest first.

## Unreleased

- **Bundled comms is now v0.2.1**, which adds porter: agent state shared with
  João's phone (Monitor app), notifications and questions, phone approvals.
  Enable per machine with `comms porter setup --approver <phone>` and
  `comms porter install-hooks`; off by default.
- **Subagents no longer vanish while they work.** Their rows follow their own
  transcript, Claude's internal no-start helper stops are ignored, and a parent
  stays visible while any subagent is live.
- **New app icon** — three hexagons (two white outlines, one orange) on a near-black
  rounded square, shared with the Monitor phone app. Run `./update.sh main` to pick it up.
- **Live session summaries are now opt-in.** The housekeeping summary agent is off
  for new installs, so a fresh install spends nothing on summaries until you enable
  **Settings → Housekeeping → Keep live session summaries**. Existing installs that
  already stored a choice (`agentMonitor.housekeepingEnabled`) keep it.
- README reorganised for first-time readers: requirements, what the installer
  changes and how to undo each item, cost & privacy, then usage and internals.
- `uninstall.sh` now prints how to remove the comms node, its launchd service, CLI,
  skills and shell alias, which it deliberately leaves installed.

## Bubbles, jump-to-session, tags and notifications

- **Floating bubbles overlay** (`⌥⌘B`) — ambient, click-through, always-on-top view
  that floats over fullscreen apps, one colored bubble per session.
- **Jump to a session** (`⌥1`–`⌥9`, `` ⌥` ``) — focus the exact Ghostty tab running
  an agent *(Ghostty only)*.
- **Custom + AI-generated tags** — name any agent freeform, or let Haiku tag it.
- **Native macOS notification banners** on needs-attention / turn-end.

See [docs/features-and-setup.md](docs/features-and-setup.md) for the full feature map,
portability tiers (what works without Ghostty) and the setup wizard.

## v2 — live session summaries + workspace

Agent Monitor does more than show *that* sessions are running — it keeps a **live,
self-updating report** of what each one is *doing*, in an IDE-style workspace.

- **Workspace UI** — the main window is a collapsible **right sidebar** (the full
  agent list) plus a **tiling pane area**. Click an agent to open its report; drag one
  into the panes to split (up to 4, then scroll). Opens near-fullscreen.
- **Housekeeping agent** — a side-car that folds each session's new activity into a
  per-session report on a budget (only on the assistant's answer, a long-turn heartbeat,
  a permission prompt, or a manual refresh — never on a bare user message). It reuses the
  transcripts the app already reads; **no new hooks**. Only the new transcript delta is
  sent each fold, and concurrent triggers are coalesced per session.
- **Three-level report** — a sticky PR-style **title**, a live phase **subtitle**, and a
  cumulative **markdown summary** (bulleted, timely-first), plus collapsible ledgers:
  features · fixes · decisions · sources · projects.
- **Reading controls** — Markdown rendering, adjustable report font (`⌘=` / `⌘−`, `⌘0`
  to reset), collapsible sections (collapsed by default).
- **Backends** — `claude -p` or `codex exec` on the logged-in subscription, or the
  metered Haiku API with an API key. `auto` prefers a key when present, then Claude,
  then Codex.
- **Settings** — UserDefaults keys
  `agentMonitor.housekeeping{Enabled,Provider,HeartbeatSec,MarkdownDir}`,
  `agentMonitor.classicView`, `agentMonitor.reportFontScale`.
- **Design doc:** [docs/housekeeping-agent.md](docs/housekeeping-agent.md).

### Upgrading from the classic version

It's a drop-in upgrade — **rebuild and you're done:**

- **Existing activity hooks keep working.** `./build.sh` also bundles the pinned
  comms release. The download is public and checksum-verified; the
  finished app needs no GitHub credentials.
- **No new hard requirements.** The summary agent uses an already logged-in `claude`
  or `codex` CLI. Claude is preferred when both exist; Codex is a fully independent
  fallback. An Anthropic API key file remains an optional metered Haiku route.
- **Summaries are opt-in** (since the change above). Enable them in Settings →
  Housekeeping; every monitored session then gets folded, which uses your selected
  local agent subscription or API key. It is incremental, but it is real usage.
  Installs from before that change that never touched the toggle stored no choice,
  so they also start with summaries off.
- **Want the old experience? Use Classic view.** A toggle in the header (and
  Settings → Interface) switches back to the original two-column live list **and turns the
  summary agent fully off** — no folds, no token use.
- **Where things live:** summaries persist as JSON in `~/.claude/agent-monitor-summaries/`
  (created automatically). Optionally export a markdown copy to a folder you choose
  (e.g. an Obsidian vault) in Settings.
