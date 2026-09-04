"""Exercise entrypoint policy before any real compiler, signer, or app launch."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class BuildEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='build-entrypoint-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'script').mkdir()
        self.script = self.root / 'script/build_and_run.sh'
        shutil.copyfile(ROOT / 'script/build_and_run.sh', self.script)
        self.source = self.root / 'Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('public static let productVersion = "0.9.0"\n'
                               'public static let productBuildVersion = "2"\n')
        self.log = self.root / 'compiler-calls.jsonl'
        binaries = self.root / 'bin'; binaries.mkdir()
        swift = binaries / 'swift'
        swift.write_text('#!' + sys.executable + '\n'
                         'import json, os, sys\n'
                         'with open(os.environ["COMPILER_CALLS"], "a") as out:\n'
                         '    out.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                         'sys.exit(71)\n')
        swift.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('FORGE_')}
        self.env.update(PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                        COMPILER_CALLS=str(self.log))

    def run_entrypoint(self, *args, **variables):
        return subprocess.run(['bash', str(self.script), *args], cwd=self.root,
                              env=dict(self.env, **variables), text=True,
                              capture_output=True, timeout=10)

    def test_inconsistent_build_override_is_rejected_before_compilation(self):
        result = self.run_entrypoint('--build-only', FORGE_BUILD_NUMBER='99')
        self.assertEqual(result.returncode, 1)
        self.assertIn('must match the compiled canonical build 2', result.stderr)
        self.assertFalse(self.log.exists())

    def test_empty_or_malformed_build_override_is_rejected(self):
        for value in ('', '0', '02', '2.0', '-1', '2\n2'):
            with self.subTest(value=value):
                self.assertEqual(self.run_entrypoint('--verify', FORGE_BUILD_NUMBER=value).returncode, 1)
        self.assertFalse(self.log.exists())

    def test_matching_build_and_existing_modes_reach_compilation(self):
        for mode in ((), ('run',), ('--verify',), ('verify',), ('--build-only',),
                     ('build-only',), ('--debug',), ('--logs',), ('--telemetry',)):
            with self.subTest(mode=mode):
                result = self.run_entrypoint(*mode, FORGE_BUILD_NUMBER='2')
                self.assertEqual(result.returncode, 71)
                self.assertIn('development smoke bundle', result.stdout)

    def test_unknown_or_extra_modes_do_not_start_compilation(self):
        for args in (('--archive',), ('--build-only', 'unexpected')):
            self.assertEqual(self.run_entrypoint(*args).returncode, 2)
        self.assertFalse(self.log.exists())

    def test_duplicate_canonical_constants_are_rejected(self):
        original = self.source.read_text()
        for line in original.splitlines():
            self.source.write_text(original + line + '\n')
            self.assertEqual(self.run_entrypoint('--build-only').returncode, 1)
        self.assertFalse(self.log.exists())

    def test_ambiguous_marketing_version_is_rejected(self):
        self.source.write_text(self.source.read_text().replace('0.9.0', '0.09.0'))
        self.assertEqual(self.run_entrypoint('--build-only').returncode, 1)
        self.assertFalse(self.log.exists())

    def test_signed_release_without_development_policy_is_rejected(self):
        result = self.run_entrypoint('--build-only', FORGE_BUILD_CONFIGURATION='release',
                                     FORGE_CODE_SIGN_IDENTITY='Apple Development')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Xcode archive/export', result.stderr)
        self.assertFalse(self.log.exists())

    def test_developer_id_selector_is_rejected_for_every_configuration(self):
        for configuration in ('debug', 'release'):
            result = self.run_entrypoint('--build-only', FORGE_BUILD_CONFIGURATION=configuration,
                                         FORGE_DEVELOPMENT_SIGNING='1',
                                         FORGE_CODE_SIGN_IDENTITY='Developer ID Application: Example')
            self.assertEqual(result.returncode, 1)
        self.assertFalse(self.log.exists())

    def test_optimized_development_build_retains_compiled_trust_flag(self):
        result = self.run_entrypoint('--build-only', FORGE_BUILD_CONFIGURATION='release',
                                     FORGE_DEVELOPMENT_SIGNING='1',
                                     FORGE_CODE_SIGN_IDENTITY='Apple Development')
        self.assertEqual(result.returncode, 71)
        args = json.loads(self.log.read_text().splitlines()[0])
        self.assertEqual(args[:5], ['build', '--configuration', 'release', '-Xswiftc',
                                    '-DFORGE_DEVELOPMENT_SIGNING'])

    def test_adhoc_optimized_smoke_build_remains_available(self):
        result = self.run_entrypoint('--build-only', FORGE_BUILD_CONFIGURATION='release')
        self.assertEqual(result.returncode, 71)
        self.assertIn('development smoke bundle', result.stdout)


if __name__ == '__main__':
    unittest.main()
