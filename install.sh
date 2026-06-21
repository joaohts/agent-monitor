#!/bin/bash
# One-shot installer for Agent Monitor.
# - Verifies prereqs (swiftc, jq, claude CLI)
# - Builds AgentMonitor.app
# - Merges hook config into ~/.claude/settings.json (idempotent, with backup)
set -euo pipefail
cd "$(dirname "$0")"

REPO_DIR="$(pwd)"
HOOK_PATH="$REPO_DIR/hooks/agent-monitor-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

# Yes/No prompt. Prompt text goes to the tty (so it's not swallowed by command
# substitution); only Y/N is emitted on stdout. Falls back to the default when
# there's no terminal (e.g. piped installs / CI), so the script never blocks.
ask() {
    local prompt="$1" default="${2:-Y}" reply hint
    hint="[Y/n]"; [ "$default" = "N" ] && hint="[y/N]"
    if [ ! -r /dev/tty ]; then echo "$default"; return; fi
    printf "    %s %s " "$prompt" "$hint" > /dev/tty
    read -r reply < /dev/tty || reply=""
    reply="${reply:-$default}"
    case "$reply" in [Yy]*) echo "Y" ;; *) echo "N" ;; esac
}

# Stable code-signing identity in a dedicated keychain the script fully controls.
# Gives the app a constant code identity across rebuilds, so macOS notification +
# Automation grants persist (ad-hoc signing churns the identity every build and
# resets those grants). Zero clicks: no login password, no Keychain dialog —
# because we own the keychain's (generated) password. Idempotent.
SIGN_IDENTITY="Agent Monitor Local"
SIGN_KC="$HOME/Library/Keychains/agent-monitor-signing.keychain-db"
SIGN_PW_FILE="$HOME/.config/agent-monitor/signing-keychain.pw"

setup_signing() {
    if [ -f "$SIGN_KC" ] && security find-identity -p codesigning "$SIGN_KC" 2>/dev/null \
         | grep -q "$SIGN_IDENTITY"; then
        echo "    ✓ stable signing identity already present"
        return 0
    fi
    command -v openssl >/dev/null 2>&1 || {
        echo "    ! openssl not found — skipping; build will ad-hoc sign"; return 0; }

    local KCPW TMPD CFG
    KCPW="$(openssl rand -base64 24)"
    TMPD="$(mktemp -d)"
    CFG="$TMPD/openssl.cnf"
    cat > "$CFG" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" -config "$CFG" >/dev/null 2>&1

    security delete-keychain "$SIGN_KC" 2>/dev/null || true
    security create-keychain -p "$KCPW" "$SIGN_KC"
    security set-keychain-settings "$SIGN_KC"                 # no auto-lock timeout
    security unlock-keychain -p "$KCPW" "$SIGN_KC"
    # Import key + cert as PEM separately — Apple's `security import` can't read
    # the PKCS#12 that OpenSSL 3 (Homebrew) writes; PEM sidesteps that entirely.
    security import "$TMPD/key.pem"  -k "$SIGN_KC" -T /usr/bin/codesign >/dev/null 2>&1
    security import "$TMPD/cert.pem" -k "$SIGN_KC" -T /usr/bin/codesign >/dev/null 2>&1
    # Let codesign use the key with no UI prompt (we own the keychain password).
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$SIGN_KC" >/dev/null 2>&1
    # codesign resolves the (untrusted, self-signed) identity by hash only if the
    # keychain is in the search list. Add it, preserving existing keychains.
    local EXISTING
    EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
    echo "$EXISTING" | grep -q "agent-monitor-signing" \
        || security list-keychains -d user -s "$SIGN_KC" $EXISTING >/dev/null 2>&1

    mkdir -p "$(dirname "$SIGN_PW_FILE")"
    printf '%s' "$KCPW" > "$SIGN_PW_FILE"
    chmod 600 "$SIGN_PW_FILE"
    rm -rf "$TMPD"

    if security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
        echo "    ✓ created stable signing identity '$SIGN_IDENTITY'"
    else
        echo "    ! signing setup didn't complete — build will fall back to ad-hoc"
        rm -f "$SIGN_PW_FILE"
    fi
}

echo "==> Agent Monitor installer"
echo "    repo:    $REPO_DIR"
echo "    hook:    $HOOK_PATH"
echo

# ── 1. Prereqs ───────────────────────────────────────────────────────────────
echo "==> Checking prerequisites..."
missing=()
command -v swiftc >/dev/null 2>&1 || missing+=("Swift compiler — run: xcode-select --install")
command -v jq     >/dev/null 2>&1 || missing+=("jq — run: brew install jq")
command -v claude >/dev/null 2>&1 || missing+=("claude CLI — install from https://claude.ai/code")

if [ ${#missing[@]} -gt 0 ]; then
    echo "    ✗ missing prerequisites:"
    for m in "${missing[@]}"; do echo "      - $m"; done
    echo
    echo "Install the above and re-run ./install.sh"
    exit 1
fi
echo "    ✓ swiftc, jq, claude all found"
echo

# ── 2. Stable signing identity (so the first build is signed with it) ───────
echo "==> Setting up stable code-signing identity..."
setup_signing
echo

# ── 3. Build ─────────────────────────────────────────────────────────────────
echo "==> Building AgentMonitor.app..."
chmod +x "$HOOK_PATH" build.sh
./build.sh
echo

# ── 3. Verify hook script runs cleanly with sample input ────────────────────
echo "==> Smoke-testing hook script..."
LINES_BEFORE=$(wc -l < "$HOME/.claude/agents.jsonl" 2>/dev/null || echo 0)
echo '{"session_id":"install_smoke","cwd":"/tmp","hook_event_name":"SessionStart"}' \
    | "$HOOK_PATH"
LINES_AFTER=$(wc -l < "$HOME/.claude/agents.jsonl" 2>/dev/null || echo 0)
if [ "$LINES_AFTER" -gt "$LINES_BEFORE" ]; then
    echo "    ✓ hook wrote 1 event"
    # Clean up the smoke-test session
    echo '{"session_id":"install_smoke","cwd":"/tmp","hook_event_name":"SessionEnd"}' \
        | "$HOOK_PATH"
else
    echo "    ✗ hook didn't write — check $HOME/.claude/agent-monitor-debug.log"
    exit 1
fi
echo

# ── 4. Merge hooks into ~/.claude/settings.json ─────────────────────────────
echo "==> Configuring hooks in $SETTINGS..."
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak.$(date +%Y%m%d_%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "    backup saved: $BACKUP"

TMP=$(mktemp)
jq --arg cmd "$HOOK_PATH" '
def add_hook(name):
    if ([.hooks[name][]?.hooks[]?.command] | any(. == $cmd)) then
        .
    else
        .hooks[name] = ((.hooks[name] // []) + [{"hooks":[{"type":"command","command":$cmd}]}])
    end;
(.hooks //= {})
| add_hook("SessionStart")
| add_hook("UserPromptSubmit")
| add_hook("Notification")
| add_hook("PermissionRequest")
| add_hook("Elicitation")
| add_hook("Stop")
| add_hook("StopFailure")
| add_hook("SessionEnd")
| add_hook("SubagentStart")
| add_hook("SubagentStop")
' "$SETTINGS" > "$TMP"

if jq -e . "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$SETTINGS"
    echo "    ✓ registered: SessionStart, UserPromptSubmit, Notification, PermissionRequest, Elicitation, Stop, StopFailure, SessionEnd, SubagentStart, SubagentStop"
else
    echo "    ✗ jq produced invalid JSON; settings.json untouched"
    rm -f "$TMP"
    exit 1
fi
echo

# ── 5. Ghostty integration (optional; only if Ghostty is installed) ─────────
GHOSTTY_APP="/Applications/Ghostty.app"
GCFG="$HOME/.config/ghostty/config"
if [ -d "$GHOSTTY_APP" ]; then
    echo "==> Ghostty detected — optional jump-to-tab / tab-title setup"
    if [ "$(ask 'Enable jump-to-tab + agent-monitor-owned tab titles (recommended)?' Y)" = "Y" ]; then

        if [ "$(ask 'Let agent-monitor own the tab title? (sets CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1)' Y)" = "Y" ]; then
            TMP2=$(mktemp)
            if jq '.env = ((.env // {}) + {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE":"1"})' "$SETTINGS" > "$TMP2" \
               && jq -e . "$TMP2" >/dev/null 2>&1; then
                mv "$TMP2" "$SETTINGS"
                echo "    ✓ CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 (applies to NEW sessions)"
            else
                rm -f "$TMP2"; echo "    ✗ couldn't update env; skipped"
            fi
        fi

        if [ "$(ask 'Stop Ghostty itself from writing titles? (edits your ghostty config)' Y)" = "Y" ]; then
            mkdir -p "$(dirname "$GCFG")"; touch "$GCFG"
            if grep -qE '^[[:space:]]*shell-integration-features' "$GCFG"; then
                echo "    ! you already set shell-integration-features — add 'no-title' to that line yourself:"
                echo "        $GCFG"
            else
                cp "$GCFG" "$GCFG.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                printf '\n# Added by Agent Monitor: let it own the tab title\nshell-integration-features = no-title\n' >> "$GCFG"
                echo "    ✓ added 'no-title' to $GCFG (reload Ghostty config / restart to apply)"
            fi
        else
            echo "    → manual: add  shell-integration-features = no-title  to $GCFG"
        fi

        echo "    ℹ On your first jump (⌥1…9), macOS will ask to let AgentMonitor control"
        echo "      Ghostty — click Allow. (One time; it's how tab focusing works.)"
    else
        echo "    skipped — jump-to-tab won't switch tabs, but every other feature works."
    fi
else
    echo "==> Ghostty not found — skipping jump-to-tab / tab-title setup."
    echo "    Core features still work fully: bubbles overlay, custom names, AI tags,"
    echo "    native notifications, hotkeys to toggle/expand the overlay."
    echo "    Jump-to-tab + tab titles need Ghostty (https://ghostty.org)."
fi
echo

# ── 6. Symlink into ~/Applications so Spotlight can find it ─────────────────
APPS_DIR="$HOME/Applications"
APP_LINK="$APPS_DIR/AgentMonitor.app"
APP_TARGET="$REPO_DIR/AgentMonitor.app"

mkdir -p "$APPS_DIR"

# Replace any existing symlink/copy with a fresh symlink to our build location
if [ -L "$APP_LINK" ] || [ -e "$APP_LINK" ]; then
    rm -rf "$APP_LINK"
fi
ln -s "$APP_TARGET" "$APP_LINK"
echo "==> Symlinked $APP_LINK → $APP_TARGET"
echo "    (search 'Agent Monitor' in Spotlight to launch it)"
echo

# ── 6. Done ─────────────────────────────────────────────────────────────────
cat <<EOF
==> Installation complete.

The floating window should now be visible. New Claude Code sessions you start in
any terminal will appear in it automatically.

First-launch notes:
  - On first AI title generation, macOS may prompt for Full Disk Access.
    Allow → AI titles + live status work.
    Deny  → basic features still work, no AI titles.
  - If Gatekeeper says "cannot verify developer": right-click AgentMonitor.app → Open.
  - Photo Library / Desktop prompts are false positives — click Don't Allow.

Useful paths:
  state:  ~/.claude/agents.jsonl
  debug:  ~/.claude/agent-monitor-debug.log
  config: $SETTINGS
  backup: $BACKUP

To rebuild after editing AgentMonitor.swift:
  ./build.sh

To remove the hooks: edit $SETTINGS or restore from $BACKUP.
EOF
