#!/usr/bin/env python3
"""Verify the GUI wrapper forwards a path without clearing existing settings."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class InstallOptionsTest(unittest.TestCase):
    def invoke(self, args):
        source = (Path(__file__).resolve().parent / 'install-local-comms.sh').read_text()
        helper = source.split('# BEGIN COMMS_INSTALL_OPTIONS\n', 1)[1].split('# END COMMS_INSTALL_OPTIONS', 1)[0]
        with tempfile.TemporaryDirectory(prefix='comms-options-') as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            # Stub records only the arguments. No installed node or user
            # configuration is touched, and the key contents are never read.
            (scripts / 'install.sh').write_text('''#!/bin/bash
python3 -c 'import json,sys;print(json.dumps(sys.argv[1:]))' "$@"
''')
            script = 'set -euo pipefail\n' + helper + '''
comms_test_bundle="$1"; shift
parse_comms_install_options "$@"
run_comms_release_installer "$comms_test_bundle" comms-v1
'''
            return subprocess.run(['/bin/bash', '-c', script, 'test', str(root), *args],
                                  capture_output=True, text=True, timeout=5)

    def test_normal_update_omits_key_override(self):
        result = self.invoke([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['--binary-name', 'comms-v1', '--skip-skills'])

    def test_selected_path_is_one_argument_without_interpolation(self):
        key_path = '/private/path with spaces/$(not-executed)-broker-key'
        result = self.invoke(['--broker-service-key-file', key_path])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['--binary-name', 'comms-v1', '--skip-skills', '--broker-service-key-file', key_path])

    def test_invalid_options_do_not_run_installer(self):
        cases = [['--broker-service-key-file'], ['--broker-service-key-file', ''],
                 ['--broker-service-key-file', '/a', '--broker-service-key-file', '/b'], ['--unknown']]
        for args in cases:
            with self.subTest(args=args):
                result = self.invoke(args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
