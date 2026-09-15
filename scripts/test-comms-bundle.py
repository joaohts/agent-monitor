#!/usr/bin/env python3
"""Exercise release integrity without private repository access or installation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="comms-bundle-test-") as tmp:
        root = Path(tmp)
        scripts = root / "scripts"
        scripts.mkdir()
        for name in ("bundle-comms.sh", "install-local-comms.sh"):
            shutil.copy2(source / name, scripts / name)
        release = root / "release"
        release.mkdir()
        stage = root / "stage"
        stage.mkdir()
        (stage / "comms").write_text("fixture executable, never executed\n")
        (stage / "VERSION").write_text("0.1.0\n")
        (stage / "CHECKSUMS").write_text(
            "".join(sha(stage / name) + "  " + name + "\n" for name in ("comms", "VERSION"))
        )
        archive = release / "comms_Darwin_arm64.tar.gz"

        def pack():
            with tarfile.open(archive, "w:gz") as tar:
                for item in stage.iterdir():
                    tar.add(item, arcname=item.name)
            digest = sha(archive)
            (release / "SHA256SUMS").write_text(digest + "  " + archive.name + "\n")
            (root / "comms-release.json").write_text(json.dumps({
                "repository": "fixture/unused", "version": "v0.1.0", "api_version": 1,
                "sha256": {archive.name: digest},
            }))

        env = os.environ | {"COMMS_RELEASE_DIR": str(release), "COMMS_ARCH": "arm64"}
        env.pop("COMMS_ALLOW_UNPINNED_DEV", None)
        resources = root / "Resources"

        def bundle():
            return subprocess.run(["bash", str(scripts / "bundle-comms.sh"), str(resources)],
                                  env=env, capture_output=True, text=True, timeout=10)

        pack()
        result = bundle()
        assert result.returncode == 0, result.stderr
        assert (resources / "CommsNode/comms").read_bytes() == (stage / "comms").read_bytes()
        initial = (resources / "CommsNode/comms").read_bytes()

        archive.write_bytes(archive.read_bytes() + b"tampered")
        result = bundle()
        assert result.returncode != 0 and "Pinned archive checksum mismatch" in result.stderr
        assert (resources / "CommsNode/comms").read_bytes() == initial

        # Even a newly pinned archive must match its internal file manifest.
        (stage / "comms").write_text("changed after manifest creation\n")
        pack()
        result = bundle()
        assert result.returncode != 0 and "contents checksum mismatch" in result.stderr
        assert (resources / "CommsNode/comms").read_bytes() == initial

        # Missing pin hashes fail the normal path; only explicit dev mode may
        # use unpinned local artifacts.
        pin = json.loads((root / "comms-release.json").read_text())
        pin["sha256"][archive.name] = ""
        (root / "comms-release.json").write_text(json.dumps(pin))
        result = bundle()
        assert result.returncode != 0 and "SHA256 pin is missing" in result.stderr
    print("Comms bundle integrity validation passed.")


if __name__ == "__main__":
    main()
