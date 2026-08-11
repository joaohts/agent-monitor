# Agent Monitor — Features, Portability & Setup

Covers the floating-bubbles / jump-to-session / tagging features and which of
them are portable across users and terminals.

---

## Feature overview

| Feature | Summary |
|---|---|
| **Floating bubbles overlay** | A separate always-on-top, click-through panel showing a bubble per live agent. Coexists with the regular main window (which is a normal-level window). Floats over fullscreen apps on other Spaces. |
| **Bubble styling** | Status dot (green=running, gray=idle/away, orange=needs-attention), pulse while running, white border, gray capsule background. |
| **Custom names / tags** | Per-session freeform tag, shown as `tag · project #N` in the bubble + main row. Right-click a row → "Name this agent…". Persisted to `~/.claude/agent-monitor-names.json`. A named session's Ghostty tab title becomes the name verbatim (unnamed sessions keep `project #N`). |
| **AI tag generation** | ✨ in the rename popover calls `claude -p --model claude-haiku-4-5` with the full transcript as context and returns a 1–3 word tag. Reuses the existing `claude -p` runner (OAuth, no API key, tools disabled). |
| **Native notifications** | macOS Notification Center banners on needs-attention / turn-end, via `UNUserNotificationCenter`. Toolbar toggle, off by default. Requires the app to be code-signed (see "Stable signing" below). |
| **Expand inactive** | `⌥⌘E` / `moon.zzz` toggle adds inactive sessions to the overlay, rendered smaller + dimmed. |
| **Jump to session** | `⌥1…9` focus the Nth bubble's Ghostty tab; `` ⌥` `` cycles. Exact: each session is locked to its Ghostty terminal's stable id (reported by the hook). |
| **agent-monitor owns the tab title** | Sets the Ghostty tab title — the custom name if one is set, else `project #N` — so the tab matches the bubble. Written directly through the session's tty (OSC), which also resolves the exact tab for ⌥N jump. When a session dies or gets remapped, its old tab is reset to the plain directory name so stale agent titles don't linger. |

### Hotkeys
| Key | Action | Needs Ghostty? |
|---|---|---|
| `⌥⌘B` | Toggle bubbles overlay | no |
| `⌥⌘C` | Move overlay to next corner | no |
| `⌥⌘E` | Expand/collapse inactive sessions | no |
| `⌥1`…`⌥9` | Jump to bubble N | **yes** |
| `` ⌥` `` | Cycle to next session | **yes** |

The jump hotkeys use **bare ⌥ + digit**, which on US-style layouts is the
special-glyph layer (™ £ ¢ …). This is fine when Option is not used to type those
(e.g. `macos-option-as-alt` off + accents via dead keys). The app only registers
these hotkeys **when Ghostty is installed**, so non-Ghostty users keep those keys.

---

## Portability tiers — who benefits

### Tier 1 — Universal (any user, any terminal)
Bubbles overlay, styling, custom names/tags, AI tag generation, native
notifications, ad-hoc codesign, expand toggle, and the overlay-control hotkeys
(`⌥⌘B/C/E`). No terminal coupling.

### Tier 2 — Ghostty-only (degrade gracefully elsewhere)
Jump-to-session, tab-title ownership, and the hook's tty capture.
- The hook self-guards on `TERM_PROGRAM=ghostty` (no-op for other terminals). It
  reports the claude process's controlling tty (a walk up the process tree — no
  AppleScript, no dependence on which tab is focused). The app resolves
  tty → Ghostty surface id once per tab by writing a uniquely-marked title
  through the tty (OSC) and reading back which surface shows it; the binding is
  cached in `~/.claude/agent-monitor-tty-map.json` and survives claude restarts
  in the same tab.
- Titles are thereafter written straight through the tty; AppleScript remains
  for listing terminals, jumping, and resetting stale titles.
- The app gates jump hotkeys + `reconcileGhostty()` on `Ghostty.isInstalled`, so
  non-Ghostty users lose no keys and run no pointless AppleScript.

### Tier 3 — Out-of-repo config (per-user; the installer can set these)
Needed for the Ghostty title feature to be flicker-free (without them, jump still
works — it's id-based — but agent-monitor fights Claude/Ghostty over the title):
- `~/.claude/settings.json` → `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = "1"`
- `~/.config/ghostty/config` → `shell-integration-features = no-title`

### Tier 4 — Permissions (one click each, cannot be scripted — macOS TCC)
- **Automation**: "AgentMonitor wants to control Ghostty" on first jump → Allow.
- **Notifications**: one prompt when banners are first enabled (off by default).

These are granted **once** and persist, thanks to stable signing (below).

### Stable signing (automatic, zero-click)

`install.sh` creates a self-signed **code-signing identity** ("Agent Monitor Local")
in a **dedicated keychain it owns** (generated password — no login password, no
Keychain dialog), then `build.sh` signs every build with it (by identity hash;
the keychain is kept in the search list). This gives the app a **constant code
identity across rebuilds**, so the notification + Automation grants stick instead
of resetting each build (which is what pure ad-hoc signing caused).

- Fully automatic in `install.sh`; idempotent (skips if the identity exists).
- `build.sh` **falls back to ad-hoc `-`** if the identity isn't set up, so the
  repo stays portable for anyone who skips it.
- Implementation note: the key/cert are imported as **PEM** (not PKCS#12) because
  Apple's `security import` can't read the p12 OpenSSL 3 / Homebrew produces.
- `uninstall.sh` removes the keychain + its password file.
- Switching from ad-hoc to this identity is a one-time change, so you may get one
  final notification re-grant + one Automation prompt; after that they persist.

---

## Setup

### Quick (Ghostty users)
```
./install.sh        # deps check, stable signing, build, register hooks,
                    # then a wizard for the Ghostty integration
```
The wizard (defaults to Yes; falls back to defaults with no TTY so piped installs
don't hang) asks whether to:
1. enable jump-to-tab + owned titles,
2. set `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`,
3. append `no-title` to the ghostty config (with backup; skips + warns if a
   `shell-integration-features` line already exists).

Then: restart existing Claude sessions (env/title changes apply to new sessions),
and press `⌥1` once to grant the Automation permission.

### If Ghostty isn't installed
The installer skips the integration section. All Tier-1 features work; jump-to-tab
and tab titles are unavailable (they require Ghostty — https://ghostty.org).

---

## How the precise jump works

There is no way for a session to signal its own terminal from inside (hooks have
no controlling TTY — verified — and Ghostty exposes no surface-id env var). So:

1. The hook runs `osascript` at `SessionStart` / `UserPromptSubmit` — moments when
   the user is provably focused in that tab — to read the focused terminal's
   stable id, guarded by cwd, and writes it as `terminal_id` on the agents.jsonl
   event.
2. agent-monitor trusts that id over any heuristic and evicts any other session
   wrongly holding it, so a bad mapping self-heals the next time you act in a tab.
3. `focus()` raises the tab by that id; falls back to cwd+occurrence if absent.

Persisted maps: `~/.claude/agent-monitor-ghostty-map.json` (session→terminal),
`~/.claude/agent-monitor-names.json` (session→custom tag).
