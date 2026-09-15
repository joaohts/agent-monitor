#!/bin/bash
# Called by the installer or first application launch. No GitHub/network access.
set -euo pipefail
bundle=${1:?usage: install-local-comms.sh BUNDLED_COMMS_DIRECTORY}
config_dir="$HOME/.config/agent-monitor"
metadata="$config_dir/comms-install.json"
command_name=comms
skill_name=open-comms

if [[ -f "$metadata" ]]; then
  command_name=$(python3 -c 'import json,pathlib,sys;print(pathlib.Path(json.load(open(sys.argv[1]))["command"]).name)' "$metadata")
  skill_name=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["skill"])' "$metadata")
else
  # Existing installations remain usable during explicit migration. A new
  # command and skill avoid redirecting active legacy receivers silently.
  if [[ -e "$HOME/.local/bin/comms" || -L "$HOME/.local/bin/comms" ]]; then command_name=comms-v1; fi
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

for skill_root in "$HOME/.claude/skills" "${CODEX_HOME:-$HOME/.codex}/skills"; do
  target="$skill_root/$skill_name"
  if [[ -e "$target/SKILL.md" ]] && ! grep -q 'Agent Monitor managed comms v1' "$target/SKILL.md"; then
    # Preserve any manually installed/custom skill rather than claiming it.
    cp -Rp "$target" "$target.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mkdir -p "$target"
  cp -R "$bundle/integration/open-comms/." "$target/"
  python3 - "$target/SKILL.md" "$installed" "$skill_name" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); command,skill=sys.argv[2:]
text=p.read_text().replace('name: open-comms\n','name: '+skill+'\n',1)
text=re.sub(r'\bcomms (?=(open|stream|identities|who|post|status|inbox|log|close|export|pair|grant|ungrant|codex|broker|events|agents|sessions|serve|prune)\b)',pathlib.Path(command).name+' ',text)
text+='\n<!-- Agent Monitor managed comms v1 -->\n\nInstalled executable: `'+command+'`. Use this absolute path if the command is absent from PATH.\n'
p.write_text(text)
PY
done

umask 077
mkdir -p "$config_dir"
python3 - "$metadata" "$installed" "$skill_name" "$data_dir" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); result={'command':sys.argv[2],'skill':sys.argv[3],'data_dir':sys.argv[4]}
p.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result))
PY
