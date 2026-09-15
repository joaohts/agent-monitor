#!/usr/bin/env python3
"""Run the installers' real skill-rendering code against executable fixtures."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

FIXTURE = r"""---
name: open-comms
description: Open agent communications.
---
Resolve from COMMS_BIN when set, otherwise use `comms`.
Quote the executable as `"${COMMS_BIN:-comms}"`.
```sh
comms open ALIAS
```
Monitor({command: "\"${COMMS_BIN:-comms}\" stream ALIAS", persistent: true})
Codex starts with `comms codex`; then use `comms open`.
"""


class InstalledSkillTest(unittest.TestCase):
    def test_existing_command_elsewhere_keeps_side_by_side_name(self):
        source = (Path(__file__).resolve().parent / 'install-local-comms.sh').read_text()
        discovery = source.split('# BEGIN COMMS_COMMAND_DISCOVERY\n', 1)[1].split('# END COMMS_COMMAND_DISCOVERY', 1)[0]
        with tempfile.TemporaryDirectory(prefix='comms-command-discovery-') as directory:
            missing_local = str(Path(directory) / 'not-installed/comms')
            # Simulate command -v finding the existing command outside the
            # destination directory, without changing PATH or running legacy code.
            script = discovery + '''
command() { [[ "$1" == -v && "$2" == comms ]] && printf '/usr/local/bin/comms\\n'; }
comms_command_present "$1"
'''
            found = subprocess.run(['/bin/bash', '-c', script, 'test', missing_local])
            self.assertEqual(found.returncode, 0)
            absent = subprocess.run(['/bin/bash', '-c', discovery + '\ncommand() { return 1; }; comms_command_present "$1"', 'test', missing_local])
            self.assertNotEqual(absent.returncode, 0)

    def test_side_by_side_resolver_and_launcher(self):
        repo = Path(__file__).resolve().parent.parent
        monitor = (repo / 'scripts/install-local-comms.sh').is_file()
        installer = repo / ('scripts/install-local-comms.sh' if monitor else 'scripts/install.sh')
        source = installer.read_text()
        renderer = source.split('# BEGIN COMMS_SKILL_RENDER\n', 1)[1].split('# END COMMS_SKILL_RENDER', 1)[0]
        skill_source = repo / 'integration/open-comms/SKILL.md'
        template = skill_source.read_text() if skill_source.exists() else FIXTURE
        with tempfile.TemporaryDirectory(prefix='comms-skill-install-') as directory:
            root = Path(directory)
            legacy = root / 'skills/open-comms/SKILL.md'
            legacy.parent.mkdir(parents=True)
            legacy.write_text('Legacy skill must remain unchanged.\n')
            generated = root / 'skills/open-comms-v1/SKILL.md'
            generated.parent.mkdir(parents=True)
            generated.write_text(template)
            # Spaces and shell metacharacters must remain literal path data.
            binary = root / 'install dir $cash "quoted" }brace' / 'comms-v1'
            binary.parent.mkdir()
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$0" "$1"\n')
            binary.chmod(0o755)
            alternate = root / 'explicit-override'
            alternate.write_text(binary.read_text())
            alternate.chmod(0o755)
            subprocess.run([sys.executable, '-c', renderer, str(generated), str(binary),
                            'open-comms-v1', 'installer test'], check=True)
            text = generated.read_text()
            self.assertIn('name: open-comms-v1\n', text)
            self.assertNotIn('${COMMS_BIN:-comms}', text)
            self.assertNotRegex(text, r'(?m)^comms\s')
            self.assertNotRegex(text, r'`comms(?: |`)')
            self.assertEqual(legacy.read_text(), 'Legacy skill must remain unchanged.\n')
            opener = re.search(r'```sh\n([^\n]+)', text).group(1)
            launcher = re.search(r'`([^`\n]+ codex)`', text).group(1)
            monitor_literal = re.search(r'Monitor\(\{\s*command:\s*("(?:\\.|[^"\\])*")', text).group(1)
            stream = json.loads(monitor_literal)
            env = os.environ.copy()
            env.pop('COMMS_BIN', None)
            for command, verb in ((opener, 'open'), (launcher, 'codex'), (stream, 'stream')):
                result = subprocess.run(['/bin/bash', '-c', command], env=env,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [str(binary), verb])
            env['COMMS_BIN'] = str(alternate)
            result = subprocess.run(['/bin/bash', '-c', opener], env=env,
                                    capture_output=True, text=True, timeout=5, check=True)
            self.assertEqual(result.stdout.splitlines(), [str(alternate), 'open'])


if __name__ == '__main__':
    unittest.main()
