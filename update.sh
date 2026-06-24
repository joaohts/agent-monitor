#!/bin/bash
# Update Agent Monitor: pull the latest code for the current branch and rebuild.
#
#   ./update.sh            # fast-forward pull current branch, then rebuild + relaunch
#   ./update.sh main       # switch to (or stay on) a branch, pull it, then rebuild
#   FAST=1 ./update.sh     # skip the optimized build (faster compile, slower app)
#
# By default the rebuild is optimized (RELEASE=1) so the running app is fast.
set -euo pipefail
cd "$(dirname "$0")"

# ── 1. Resolve target branch ────────────────────────────────────────────────
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
TARGET_BRANCH="${1:-$CURRENT_BRANCH}"

echo "==> Updating Agent Monitor"
echo "    branch:  $TARGET_BRANCH"
echo

# ── 2. Refuse to clobber uncommitted changes ────────────────────────────────
# Untracked files are fine; only tracked modifications would be lost by a pull.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "    ✗ you have uncommitted changes to tracked files."
    echo "      Commit or stash them first, then re-run ./update.sh"
    echo
    git status --short
    exit 1
fi

# ── 3. Switch branch if a different one was requested ───────────────────────
if [ "$TARGET_BRANCH" != "$CURRENT_BRANCH" ]; then
    echo "==> Switching $CURRENT_BRANCH → $TARGET_BRANCH"
    git checkout "$TARGET_BRANCH"
fi

# ── 4. Pull (fast-forward only — never a surprise merge commit) ─────────────
echo "==> Pulling latest from origin/$TARGET_BRANCH..."
BEFORE="$(git rev-parse HEAD)"
git pull --ff-only origin "$TARGET_BRANCH"
AFTER="$(git rev-parse HEAD)"

if [ "$BEFORE" = "$AFTER" ]; then
    echo "    ✓ already up to date ($AFTER)"
else
    echo "    ✓ updated $BEFORE → $AFTER"
fi
echo

# ── 5. Rebuild + relaunch ───────────────────────────────────────────────────
echo "==> Rebuilding..."
chmod +x build.sh
if [ "${FAST:-0}" = "1" ]; then
    ./build.sh
else
    RELEASE=1 ./build.sh
fi
echo
echo "==> Done. Agent Monitor is running the latest build."
