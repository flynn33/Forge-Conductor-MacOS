"""Exercise daemon identity sealing with real signed universal Mach-O files."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "script" / "seal_filesystem_daemon_identity.sh"
PROJECT = REPOSITORY / "ForgeConductor.xcodeproj"
HASH_KEYS = {
    "arm64": "ForgeFilesystemDaemonCDHashArm64",
    "x86_64": "ForgeFilesystemDaemonCDHashX86_64",
}


def command(*arguments, env=None):
    return subprocess.run(
        [str(argument) for argument in arguments],
        env=env, capture_output=True, text=True, timeout=30,
    )


def require_success(result):
    if result.returncode:
        raise AssertionError(
            f"{result.args!r} exited {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result.stdout + result.stderr


@unittest.skipUnless(sys.platform == "darwin", "requires macOS signing tools")
class SealFilesystemDaemonIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = tempfile.TemporaryDirectory(prefix="forge daemon signing ")
        cls.addClassCleanup(fixture.cleanup)
        root = Path(fixture.name)
        source = root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        cls.signed_binary = root / "universal-daemon"
        require_success(command(
            "/usr/bin/xcrun", "clang", "-Werror", "-arch", "arm64",
            "-arch", "x86_64", source, "-o", cls.signed_binary,
        ))
        require_success(command(
            "/usr/bin/codesign", "--force", "--sign", "-",
            "--timestamp=none", cls.signed_binary,
        ))
        require_success(command(
            "/usr/bin/codesign", "--verify", "--strict", cls.signed_binary,
        ))
        architectures = require_success(command(
            "/usr/bin/lipo", "-archs", cls.signed_binary,
        )).split()
        if set(architectures) != set(HASH_KEYS):
            raise AssertionError(f"Unexpected fixture architectures: {architectures}")
        cls.expected_hashes = {}
        for architecture, key in HASH_KEYS.items():
            details = require_success(command(
                "/usr/bin/codesign", "--display", "--verbose=4",
                "--arch", architecture, cls.signed_binary,
            ))
            match = re.search(r"^CDHash=([0-9a-fA-F]{40})$", details, re.MULTILINE)
            if match is None:
                raise AssertionError(f"Missing fixture hash for {architecture}")
            cls.expected_hashes[key] = match.group(1).lower()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="forge daemon seal ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.products = self.root / "Build Products"
        self.products.mkdir()
        self.uninstalled = self.root / "Custom Intermediates" / "UninstalledProducts"
        self.daemon = self.uninstalled / "macosx" / "forge-filesystem-daemon"
        self.daemon.parent.mkdir(parents=True)
        shutil.copyfile(self.signed_binary, self.daemon)
        self.alias = self.products / "forge-filesystem-daemon"
        self.source_plist = self.root / "Source Info.plist"
        self.source_values = {
            "CFBundleIdentifier": "example.daemon-seal-test",
            "PreservedValue": ["fixture", 7],
            **{key: "obsolete" for key in HASH_KEYS.values()},
        }
        self.source_plist.write_bytes(plistlib.dumps(self.source_values))
        self.original_source = self.source_plist.read_bytes()
        self.output = self.root / "Sealed Info.plist"
        self.original_output = plistlib.dumps({"ExistingSeal": "must survive rejection"})
        self.output.write_bytes(self.original_output)
        self.environment = os.environ.copy()
        for key in (
            "DEPLOYMENT_LOCATION", "BUILT_PRODUCTS_DIR", "OBJROOT",
            "UNINSTALLED_PRODUCTS_DIR", "PLATFORM_NAME", "TEMP_DIR",
        ):
            self.environment.pop(key, None)
        self.archive_environment = {
            **self.environment,
            "DEPLOYMENT_LOCATION": "YES",
            "BUILT_PRODUCTS_DIR": str(self.products),
            "UNINSTALLED_PRODUCTS_DIR": str(self.uninstalled),
            # A custom uninstalled-products directory need not be below OBJROOT.
            "OBJROOT": str(self.root / "Different Object Root"),
            "PLATFORM_NAME": "macosx",
        }

    def seal(self, daemon=None, source=None, environment=None):
        return command(
            "/bin/bash", SCRIPT,
            self.daemon if daemon is None else daemon,
            self.source_plist if source is None else source,
            self.output,
            env=self.environment if environment is None else environment,
        )

    def assert_sealed(self, result):
        require_success(result)
        self.assertEqual(
            plistlib.loads(self.output.read_bytes()),
            {**self.source_values, **self.expected_hashes},
        )
        self.assertEqual(self.source_plist.read_bytes(), self.original_source)

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), self.original_output)
        self.assertEqual(self.source_plist.read_bytes(), self.original_source)

    def test_regular_file_seals_both_architectures_without_archive_context(self):
        self.assert_sealed(self.seal())

    def test_relative_and_absolute_aliases_remain_rejected(self):
        for target in (self.daemon, os.path.relpath(self.daemon, self.products)):
            with self.subTest(target=str(target)):
                self.alias.symlink_to(target)
                self.assert_rejected(self.seal(self.alias))
                self.assert_rejected(self.seal(self.alias, environment=self.archive_environment))
                self.alias.unlink()

    def test_missing_daemon_preserves_existing_seal(self):
        self.assert_rejected(self.seal(self.root / "missing-daemon"))

    def test_broken_archive_alias_preserves_existing_seal(self):
        self.alias.symlink_to(self.daemon)
        self.daemon.unlink()
        self.assert_rejected(self.seal(self.alias, environment=self.archive_environment))

    def test_unsigned_regular_and_archive_products_preserve_existing_seal(self):
        require_success(command("/usr/bin/codesign", "--remove-signature", self.daemon))
        self.assertNotEqual(command(
            "/usr/bin/codesign", "--verify", "--strict", self.daemon,
        ).returncode, 0)
        self.assert_rejected(self.seal())
        self.assert_rejected(self.seal(environment=self.archive_environment))

    def test_missing_source_plist_preserves_existing_seal(self):
        self.assert_rejected(self.seal(source=self.root / "Missing Info.plist"))

    def test_linked_source_plist_preserves_existing_seal(self):
        linked_source = self.root / "Linked Info.plist"
        linked_source.symlink_to(self.source_plist)
        self.assert_rejected(self.seal(source=linked_source))

    def test_build_and_archive_resolve_direct_products_in_both_configurations(self):
        for configuration in ("Debug", "Release"):
            for action in ("build", "archive"):
                for target in ("ForgeConductor", "forge-conductor"):
                    with self.subTest(configuration=configuration, action=action,
                                      target=target):
                        result = command(
                            "/usr/bin/xcodebuild", "-project", PROJECT,
                            "-scheme", target, "-configuration", configuration,
                            "-destination", "platform=macOS,arch=arm64",
                            "-derivedDataPath", self.root / "Build Settings",
                            "-showBuildSettings", "-json", action,
                            env=self.environment,
                        )
                        require_success(result)
                        settings = {row["target"]: row["buildSettings"]
                                    for row in json.loads(result.stdout)}
                        values = settings[target]
                        self.assertEqual(values["DEPLOYMENT_LOCATION"],
                                         "YES" if action == "archive" else "NO")
                        expected = (Path(values["UNINSTALLED_PRODUCTS_DIR"]) /
                                    values["PLATFORM_NAME"] if action == "archive"
                                    else Path(values["BUILT_PRODUCTS_DIR"]))
                        self.assertEqual(values["FORGE_FILESYSTEM_DAEMON_PRODUCT"],
                                         str(expected / "forge-filesystem-daemon"))

    def test_both_build_phases_seal_the_declared_direct_product(self):
        result = command("/usr/bin/plutil", "-convert", "json", "-o", "-",
                         PROJECT / "project.pbxproj")
        require_success(result)
        objects = json.loads(result.stdout)["objects"]
        phases = [value for value in objects.values()
                  if value.get("isa") == "PBXShellScriptBuildPhase"
                  and SCRIPT.name in value.get("shellScript", "")]
        self.assertEqual(len(phases), 2)
        derived = self.root / "Derived Info"
        environment = {**self.environment, "SRCROOT": str(REPOSITORY),
                       "DERIVED_FILE_DIR": str(derived),
                       "BUILT_PRODUCTS_DIR": str(self.products),
                       "FORGE_FILESYSTEM_DAEMON_PRODUCT": str(self.daemon)}
        def expand(value):
            return re.sub(r"\$\(([^)]+)\)",
                          lambda match: environment[match.group(1)], value)
        for phase in phases:
            with self.subTest(output=phase["outputPaths"]):
                inputs = [Path(expand(path)) for path in phase["inputPaths"]]
                self.assertIn(self.daemon, inputs)
                source = next(path for path in inputs if path.suffix == ".plist")
                original = source.read_bytes()
                require_success(command("/bin/sh", "-c", phase["shellScript"],
                                        env=environment))
                output = Path(expand(phase["outputPaths"][0]))
                self.assertEqual(plistlib.loads(output.read_bytes()),
                                 {**plistlib.loads(original), **self.expected_hashes})
                self.assertEqual(source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
