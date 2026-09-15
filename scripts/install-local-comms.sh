#!/bin/bash
# Called by the installer or first application launch. No GitHub/network access.
set -euo pipefail
bundle=${1:?usage: install-local-comms.sh BUNDLED_COMMS_DIRECTORY}
config_dir="$HOME/.config/agent-monitor"
metadata="$config_dir/comms-install.json"
command_name=comms
skill_name=open-comms
skill_backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/comms/skill-backups"

# BEGIN COMMS_SKILL_BACKUP
backup_comms_skill() {
  local comms_skill_source="$1" comms_skill_harness="$2" comms_skill_name="$3" comms_backup_root="$4"
  local comms_backup_batch
  comms_backup_batch=$(umask 077; mkdir -p "$comms_backup_root"; mktemp -d "$comms_backup_root/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  mkdir -m 700 "$comms_backup_batch/$comms_skill_harness"
  cp -Rp "$comms_skill_source" "$comms_backup_batch/$comms_skill_harness/$comms_skill_name"
  printf 'Preserved skill backup: %s\n' "$comms_backup_batch/$comms_skill_harness/$comms_skill_name" >&2
}
# END COMMS_SKILL_BACKUP


# BEGIN COMMS_COMMAND_DISCOVERY
comms_command_present() {
  [[ -e "$1" || -L "$1" ]] || command -v comms >/dev/null 2>&1
}
# END COMMS_COMMAND_DISCOVERY

if [[ -f "$metadata" ]]; then
  command_name=$(python3 -c 'import json,pathlib,sys;print(pathlib.Path(json.load(open(sys.argv[1]))["command"]).name)' "$metadata")
  skill_name=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["skill"])' "$metadata")
else
  # Existing installations remain usable during explicit migration. A new
  # command and skill avoid redirecting active legacy receivers silently.
  if comms_command_present "$HOME/.local/bin/comms"; then command_name=comms-v1; fi
  if [[ -f "$HOME/.claude/skills/open-comms/SKILL.md" || -f "${CODEX_HOME:-$HOME/.codex}/skills/open-comms/SKILL.md" ]]; then skill_name=open-comms-v1; fi
fi
case "$command_name:$skill_name" in *[!A-Za-z0-9:._-]*) printf 'Invalid saved comms installation metadata\n' >&2; exit 1 ;; esac

# The release installer verifies internal checksums before executing the binary,
# preserves the existing node data directory and broker role, then uses launchd.
install_output=$(bash "$bundle/scripts/install.sh" --binary-name "$command_name" --skip-skills)
printf '%s\n' "$install_output" >&2
installed="$HOME/.local/bin/$command_name"
data_dir=$(python3 -c '
import json,sys
for line in reversed(sys.stdin.read().splitlines()):
    try: value=json.loads(line)
    except ValueError: continue
    if isinstance(value,dict) and value.get("data_dir"): print(value["data_dir"]); break
else: raise SystemExit("Installer did not report a ready node data directory")
' <<< "$install_output")

for skill_harness in claude codex; do
  if [[ "$skill_harness" == claude ]]; then skill_root="$HOME/.claude/skills"; else skill_root="${CODEX_HOME:-$HOME/.codex}/skills"; fi
  target="$skill_root/$skill_name"
  if [[ -e "$target/SKILL.md" ]] && ! grep -q 'Agent Monitor managed comms v1' "$target/SKILL.md"; then
    # Preserve any manually installed/custom skill rather than claiming it.
    backup_comms_skill "$target" "$skill_harness" "$skill_name" "$skill_backup_root"
  fi
  mkdir -p "$target"
  cp -R "$bundle/integration/open-comms/." "$target/"
  python3 - "$target/SKILL.md" "$installed" "$skill_name" 'Agent Monitor managed comms v1' <<'PY'
# BEGIN COMMS_SKILL_RENDER
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]); command=str(pathlib.Path(sys.argv[2]).absolute())
skill,marker=sys.argv[3:5]; label=pathlib.Path(command).name
escaped=re.sub(r'([\\$`"])',r'\\\1',command)
resolver='${COMMS_BIN:-"'+escaped+'"}'
executable='"'+resolver+'"'
text=p.read_text().replace('name: open-comms\n','name: '+skill+'\n',1)
preamble='Resolve the CLI from `COMMS_BIN` when set, otherwise use `comms`. In all\ncommands below, `comms` means that resolved executable. Quote the executable\nas `"${COMMS_BIN:-comms}"` in shell commands; never overwrite PATH or fall back\nto a legacy board when the new node is unavailable.\n'
text=text.replace(preamble,'Resolve the CLI from `COMMS_BIN` when set; otherwise use `'+command+'`.\nIn prose, `'+label+'` names that executable. Shell examples honor the same override.\nNever change PATH or fall back to a legacy board when the node is unavailable.\n',1)
def monitor(match):
    value=json.loads(match.group('command')).replace('${COMMS_BIN:-comms}',resolver)
    value=re.sub(r'^comms(?=\s|$)',lambda _:executable,value)
    return match.group('prefix')+json.dumps(value,ensure_ascii=False)
text=re.sub(r'(?P<prefix>Monitor\(\{\s*command:\s*)(?P<command>"(?:\\.|[^"\\])*")',monitor,text)
text=text.replace('${COMMS_BIN:-comms}',resolver)
text=re.sub(r'(?m)^comms(?=\s)',lambda _:executable,text)
text=re.sub(r'`comms(?= |`)',lambda _:'`'+label,text)
codex_sentence='**Codex:** launch or explicitly resume through `'+label+' codex` first.'
text=text.replace(codex_sentence,codex_sentence+'\n\n```sh\n'+executable+' codex\n```\n',1)
text+='\n<!-- '+marker+' -->\n'
p.write_text(text)
# END COMMS_SKILL_RENDER
PY
done

umask 077
mkdir -p "$config_dir"
python3 - "$metadata" "$installed" "$skill_name" "$data_dir" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); result={'command':sys.argv[2],'skill':sys.argv[3],'data_dir':sys.argv[4]}
p.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result))
PY
