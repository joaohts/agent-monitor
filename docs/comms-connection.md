# Comms node setup and migration

Agent Monitor is a local client of the independently running comms node. The
node, CLI, encryption, broker role, storage, and session-delivery adapters live in
[`joaohts/comms`](https://github.com/joaohts/comms). The app does not read a bearer
token from Claude settings, download executable code from a broker, or own an
agent's receiving stream.

## Release and installation contract

`comms-release.json` pins the release tag, local API version, and both macOS
archive SHA256 digests. A normal build verifies the committed archive digest,
the release's `SHA256SUMS`, its internal `CHECKSUMS`, and the embedded version.
The verified executable, installer, and integration skill are bundled in
`AgentMonitor.app/Contents/Resources/CommsNode/`.

The node repository may be private. A source builder can use their own existing
GitHub CLI authentication, or supply an already downloaded release directory:

```sh
gh release download v0.1.3 --repo joaohts/comms \
  --pattern 'comms_Darwin_*.tar.gz' --pattern SHA256SUMS --dir /path/to/release
COMMS_RELEASE_DIR=/path/to/release NO_LAUNCH=1 ./build.sh
```

No token is embedded in the app, committed to this repository, or needed at
runtime. Binary archives and app bundles are ignored by Git. Public CI performs
compiler/client checks without obtaining the private release; release packaging
must use the verified pinned artifacts.

`./install.sh` installs the node before launching the viewer. Opening a built app
also installs it on first use if needed. The installation is per OS user:

| Item | Default location |
|---|---|
| Supervised node | `~/Library/LaunchAgents/com.joaohts.comms.plist` |
| Node identity, keys and local messages | `~/.local/share/comms/node.db` |
| Optional broker queues | `~/.local/share/comms/broker.db` |
| Owner-only API socket | `~/.local/share/comms/node.sock` |
| CLI | `~/.local/bin/comms` (or `comms-v1` during coexistence) |
| Installation metadata | `~/.config/agent-monitor/comms-install.json` |
| Skills | `~/.claude/skills/` and `~/.codex/skills/` |

The release installer preserves an existing supervised node's data directory and
broker role. The app reads local JSON through its bundled CLI, with bounded
concurrency, response sizes and deadlines. Its `events` subprocess observes
state changes. Only the actual Claude/Codex/service receiver consumes mail.
Local event refreshes never trigger a broker query; remote discovery is a
separate dashboard refresh while that view is open.

## First use

Use `/open-comms worker` in Claude or a supported Codex session. A fresh identity
is ephemeral and local-only. `/open-comms brain --persistent` saves/resumes its
identity by alias. Add `--global` explicitly for remote discovery and delivery.
Resuming a new attachment does not silently restore global scope.

Claude must run `comms stream ALIAS` inside its real Monitor tool. A stream started
by the GUI, a detached shell, or another process cannot replace that ownership.
Codex must use an app-server integration that inserts tool output into the exact
thread. Terminal injection as a user prompt is not an accepted fallback. The GUI
shows registered-but-offline identities until their receiver is connected.

The identity list provides copyable resume commands. Resuming belongs inside the
target harness; the GUI does not impersonate it or take over an occupied identity.
History reads are observations and never acknowledge or consume messages.

## Pairing, grants and remote history

1. Optionally configure the broker URL in **Settings → Comms node**.
2. Copy the public identity bundle and exchange it outside the broker through a
   channel where the other machine's identity can be verified.
3. Import the verified peer JSON, choosing a local nickname.
4. Grant that peer permission to discover/send to global agents, and optionally
   to read their global message history.

Grants are directional. Granting Mac access to Pi does not grant Pi permission to
send an agent reply to Mac. Authenticated protocol receipts are allowed for an
existing message without the reverse messaging grant. Remote history responses
exclude same-machine traffic and require their own history permission. The node
serves those encrypted online queries; the broker holds no plaintext history.

GUI history queries use explicit local-operator mode, not a made-up agent sender.
Same-OS-user access is the local security boundary. Agent sessions still have
their own local/global scope restrictions.

## Migration from the legacy board

The new implementation has fresh machine identities and explicit peer grants.
Legacy history is retained separately, never imported automatically. Legacy
`COMMS_API`, `COMMS_TOKEN`, and `COMMS_HOST` settings remain untouched.

On a machine with an existing `~/.local/bin/comms`, installation creates
`comms-v1`. If an `open-comms` skill already exists, the new integration is named
`open-comms-v1`. Its instructions contain the exact installed executable path.
Existing receivers keep using the legacy command/skill while new sessions can
test `/open-comms-v1 worker` and `comms-v1 who`.

Skill backups live outside discovery roots, under
`~/.local/state/comms/skill-backups/<unique timestamp>/<claude-or-codex>/<skill>`,
or the configured `XDG_STATE_HOME`. They preserve old content without registering
a duplicate live skill.

After verifying migration, the owner can explicitly switch the default command
and skill, preserving the old files as backups. The installer never rewrites
active legacy sessions, changes their tokens, restarts their broker, or merges
their databases. Back up a live SQLite database through its backup API; copying
only the `.db` file while WAL is active loses uncheckpointed changes.

## Updates, failure and rollback

Viewer builds do not restart the node. A compatible installed node can remain
running across viewer updates. **Install / repair bundled node** performs an
explicit node install/restart, preserving identity and queue data. The service
drains pending handoffs before exit and clients reconnect. Incompatible API
versions are shown clearly; the viewer does not silently replace a working node.

The node and viewer share machine resources, but have independent process
lifecycles. Stop or freeze the GUI and the CLI must still open a new agent, list
presence, send, and receive through the harness. A node restart does not retire
ephemeral agents whose actual harness processes remain alive.

For rollback, stop the new node with:

```sh
launchctl bootout gui/$(id -u)/com.joaohts.comms
```

Keep its data directory intact. Continue legacy sessions using the preserved
legacy command, skill, and broker. Reinstall a prior new-node binary only if it
supports the on-disk schema, or restore a consistent backup. Losing the private
key loses that machine identity permanently; v1 has no key recovery or rotation.

Uninstalling the Agent Monitor viewer leaves the independently installed node,
keys and message history intact. Remove that separate service only when intended.

## Validation

```sh
bash -n build.sh install.sh scripts/bundle-comms.sh scripts/install-local-comms.sh
python3 scripts/test-comms-bundle.py
swiftc CommsNodeClient.swift scripts/validate-comms-client.swift \
  -o /tmp/validate-comms-client && /tmp/validate-comms-client
COMMS_RELEASE_DIR=/path/to/release NO_LAUNCH=1 ADHOC_SIGN=1 ./build.sh
```

For public contributor compiler checks only:

```sh
COMMS_SKIP_BUNDLE=1 NO_LAUNCH=1 ADHOC_SIGN=1 ./build.sh
```

That produces a compiler-check app without a distributable node. Unpinned local
development archives require `COMMS_ALLOW_UNPINNED_DEV=1`; never distribute them.
The normal build refuses missing hashes, altered archives or mismatched versions.
