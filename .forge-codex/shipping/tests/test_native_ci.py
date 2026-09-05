"""Execute native CI orchestration with disposable tool fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
STUB = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TOOL_CALLS'], 'a') as out:
    out.write(json.dumps([name] + args) + '\n')
if name == os.environ.get('FAIL_COMMAND') and os.environ.get('FAIL_FRAGMENT', '') in ' '.join(args):
    print('fixture command failure')
    sys.exit(77)
if name == 'swift' and '--xunit-output' in args:
    pathlib.Path(args[args.index('--xunit-output') + 1]).write_text('<testsuite tests="1"/>')
print('arm64' if name == 'uname' else 'fixture tool output')
'''


class NativeCITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-ci-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / '.forge-codex/shipping/scripts/native_ci.sh'
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / '.forge-codex/shipping/scripts/native_ci.sh', self.script)
        binaries = self.root / 'bin'; binaries.mkdir()
        for name in ('git', 'sw_vers', 'uname', 'xcodebuild', 'swift', 'python3'):
            stub = binaries / name
            stub.write_text('#!' + sys.executable + '\n' + STUB)
            stub.chmod(0o755)
        self.log = self.root / 'tool-calls.jsonl'
        self.output = self.root / 'results'
        self.env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                        TOOL_CALLS=str(self.log), FORGE_CI_OUTPUT_DIR=str(self.output))

    def run_lane(self, lane, **variables):
        return subprocess.run(['bash', str(self.script), lane], cwd=self.root,
                              env=dict(self.env, **variables), text=True,
                              capture_output=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_integrity_failures_propagate_through_logging(self):
        for command in ('unittest', 'test_seal_filesystem_daemon_identity.py',
                        'scan_attribution.py', 'versions', 'xcode --repo'):
            with self.subTest(command=command):
                result = self.run_lane('integrity', FAIL_COMMAND='python3', FAIL_FRAGMENT=command)
                self.assertEqual(result.returncode, 77)

    def test_swift_test_failure_is_not_hidden_by_tee(self):
        result = self.run_lane('swift-debug', FAIL_COMMAND='swift', FAIL_FRAGMENT='test')
        self.assertEqual(result.returncode, 77)
        self.assertIn('fixture command failure', (self.output / 'swift-tests.log').read_text())

    def test_xcode_failure_is_not_hidden_by_tee(self):
        result = self.run_lane('xcode-release', FAIL_COMMAND='xcodebuild', FAIL_FRAGMENT='-scheme')
        self.assertEqual(result.returncode, 77)
        self.assertIn('fixture command failure', (self.output / 'ForgeConductor-build.log').read_text())

    def test_debug_and_release_swift_lanes_retain_results_and_warnings_policy(self):
        for configuration in ('debug', 'release'):
            result = self.run_lane('swift-' + configuration)
            self.assertEqual(result.returncode, 0, result.stderr)
            call = [args for args in self.calls() if args[:2] == ['swift', 'test']][-1]
            self.assertIn('-warnings-as-errors', call)
            self.assertEqual(call[call.index('--configuration') + 1], configuration)
            self.assertTrue((self.output / 'swift-tests.xml').is_file())

    def test_xcode_lanes_compile_both_products_without_signing(self):
        for configuration in ('debug', 'release'):
            result = self.run_lane('xcode-' + configuration)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [args for args in self.calls() if args[0] == 'xcodebuild' and args[-1] == 'build'][-2:]
            self.assertEqual({args[args.index('-scheme') + 1] for args in calls},
                             {'ForgeConductor', 'forge-conductor'})
            for call in calls:
                self.assertIn('CODE_SIGNING_ALLOWED=NO', call)
                self.assertIn('SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', call)
                self.assertIn('GCC_TREAT_WARNINGS_AS_ERRORS=YES', call)
                self.assertEqual(call[call.index('-configuration') + 1], configuration.title())

    def test_unknown_lane_does_not_run_tools(self):
        self.assertEqual(self.run_lane('archive').returncode, 2)
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
