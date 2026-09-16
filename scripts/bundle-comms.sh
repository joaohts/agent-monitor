#!/bin/bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
resource_dir=${1:?usage: bundle-comms.sh APP_RESOURCE_DIRECTORY}
release_tag=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$repo_dir/comms-release.json")
repository=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["repository"])' "$repo_dir/comms-release.json")
arch=${COMMS_ARCH:-$(uname -m)}
case "$arch" in arm64) artifact=comms_Darwin_arm64.tar.gz ;; x86_64|amd64) artifact=comms_Darwin_amd64.tar.gz ;; *) printf 'Unsupported comms architecture: %s\n' "$arch" >&2; exit 1 ;; esac

if [[ -n "${COMMS_RELEASE_DIR:-}" ]]; then
  release_dir=$COMMS_RELEASE_DIR
else
  release_dir="$repo_dir/.build/comms-downloads/$release_tag"
  mkdir -p "$release_dir"
  if [[ ! -f "$release_dir/$artifact" || ! -f "$release_dir/SHA256SUMS" ]]; then
    command -v gh >/dev/null 2>&1 || { printf 'Use an authenticated gh CLI or provide COMMS_RELEASE_DIR with verified release files.\n' >&2; exit 1; }
    gh release download "$release_tag" --repo "$repository" --dir "$release_dir" --pattern "$artifact" --pattern SHA256SUMS --clobber
  fi
fi

python3 - "$repo_dir/comms-release.json" "$release_dir" "$artifact" "$resource_dir" "${COMMS_ALLOW_UNPINNED_DEV:-0}" <<'PY'
import hashlib,json,pathlib,shutil,sys,tarfile,tempfile
pin_path,release,artifact,resources,dev=sys.argv[1:]
pin=json.loads(pathlib.Path(pin_path).read_text()); release=pathlib.Path(release)
archive=release/artifact; digest=hashlib.sha256(archive.read_bytes()).hexdigest()
expected=pin['sha256'].get(artifact)
if expected:
    if digest!=expected: raise SystemExit('Pinned archive checksum mismatch: '+artifact)
elif dev!='1': raise SystemExit('The release SHA256 pin is missing; finish release pinning before distributing this app.')
listed=dict((name.strip().lstrip('*'),sha) for sha,name in (line.split(None,1) for line in (release/'SHA256SUMS').read_text().splitlines()))
if listed.get(artifact)!=digest: raise SystemExit('Release SHA256SUMS mismatch: '+artifact)
resources=pathlib.Path(resources); resources.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='agent-monitor-comms-') as tmp:
    stage=pathlib.Path(tmp)
    with tarfile.open(archive) as tar:
        for item in tar.getmembers():
            target=(stage/item.name).resolve()
            if not target.is_relative_to(stage.resolve()) or not (item.isfile() or item.isdir()):
                raise SystemExit('Unsafe release archive entry: '+item.name)
        tar.extractall(stage)
    version=(stage/'VERSION').read_text().strip()
    if version!=pin['version'].removeprefix('v') and dev!='1': raise SystemExit('Release version mismatch: '+version)
    for line in (stage/'CHECKSUMS').read_text().splitlines():
        sha,name=line.split('  ',1); path=(stage/name).resolve()
        if not path.is_relative_to(stage.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest()!=sha:
            raise SystemExit('Release contents checksum mismatch: '+name)
    destination=resources/'CommsNode'
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(stage,destination)
    (resources/'comms-bundle.json').write_text(json.dumps({'version':version,'api_version':pin['api_version'],'artifact':artifact,'sha256':digest},indent=2)+'\n')
print('Bundled comms '+version+' ('+artifact+', SHA256 '+digest[:12]+'…)')
PY
install -m 755 "$script_dir/install-local-comms.sh" "$resource_dir/install-local-comms.sh"
