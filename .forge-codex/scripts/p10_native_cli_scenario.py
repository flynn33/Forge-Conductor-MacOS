#!/usr/bin/env python3
"""Reviewed installed CLI feature contract and current-source provenance checks."""
from __future__ import annotations

import copy
from datetime import datetime
import hashlib
import json
import pathlib
import re
import shlex
import tempfile
from typing import Any

from evidence_support import BoundedReadBudget, EvidenceSupportError, current_git_head, decode_strict_json_object, read_bounded_repository_bytes, source_manifest
from p10_feature_baseline import EXPECTED_SIGNING_ARTIFACTS
from p10_source_candidate import validate_source_candidate
import p10_cli_version_help as cli
from record_command import execute_command
from qualify_signed_shell_manager import validate_application_bundle, sandboxed_install_command, QualificationError

FEATURE_ID = "CLI-VERSION-HELP"
RUNNER_KIND = "native_cli_version_help"
ROOT_TOKEN = "@validated-cli-installation"
INSTALL_REPORT = ".forge-codex/evidence/P10-cli-installation.json"
SCOPE = "development-installed-release"
BUILD_FILES = (
    "Contents/MacOS/Forge Conductor", "Contents/Helpers/forge-conductor",
    "Contents/Helpers/forge-runtime-launcher", "Contents/MacOS/forge-filesystem-daemon",
    "Contents/Frameworks/ForgeConductorCore.framework/Versions/A/ForgeConductorCore",
    "Contents/Info.plist", "Contents/Library/LaunchDaemons/com.forge-conductor.filesystem-daemon.plist",
)
EXPECTED = {"contract": "native-cli-version-help-v1", "artifact_id": "forge-conductor-cli", "scope": SCOPE}
SCENARIO = {
    "scenario_id": "CLI-VERSION-HELP-NATIVE",
    "runner": {"kind": RUNNER_KIND, "timeout_seconds": 180},
    "installation": {"root": ROOT_TOKEN, "configuration": "Release", "process_artifact_id": "forge-conductor-cli", "artifacts": [
        {"artifact_id": key, "relative_path": value["relative_path"], "kind": value["installation_kind"]}
        for key, value in EXPECTED_SIGNING_ARTIFACTS.items()
    ]},
    "assertions": [
        {"feature_id": FEATURE_ID, "assertion_id": FEATURE_ID + ".production-path", "selector": "cli.version-help", "evidence_kind": "native-cli-version-help", "expected": EXPECTED},
        {"feature_id": FEATURE_ID, "assertion_id": FEATURE_ID + ".signed-product.forge-conductor-cli", "selector": "signing.forge-conductor-cli", "evidence_kind": "codesign-identity", "expected": {"artifact_id": "forge-conductor-cli", "team_id": "9AQ2C2838M", "identifier": "com.forge-conductor.cli", "hardened_runtime": True}},
    ],
}


def require(value: bool, message: str) -> None:
    if not value:
        raise EvidenceSupportError(message)


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def scenario_valid(probe: Any, *, allow_bound_root: bool = False) -> bool:
    if not isinstance(probe, dict):
        return False
    expected = copy.deepcopy(SCENARIO)
    if allow_bound_root:
        installation = probe.get("installation")
        if not isinstance(installation, dict):
            return False
        root = installation.get("root")
        if not isinstance(root, str) or not root.startswith("/") or pathlib.Path(root).name != "Forge Conductor.app":
            return False
        expected["installation"]["root"] = root
    return probe == expected


def bound_probe(app: pathlib.Path) -> dict[str, Any]:
    result = copy.deepcopy(SCENARIO)
    result["installation"]["root"] = str(app)
    return result


def probe_from_observation(probe: dict[str, Any], observation: dict[str, Any]) -> dict[str, Any]:
    require(scenario_valid(probe) or scenario_valid(probe, allow_bound_root=True), "native CLI scenario contract changed")
    require(isinstance(observation, dict) and isinstance(observation.get("results"), list), "native CLI observation result shape changed")
    results = [item for item in observation["results"] if isinstance(item, dict) and item.get("selector") == "cli.version-help"]
    require(len(results) == 1, "native CLI observation has no unique semantic transcript")
    require(isinstance(results[0].get("provenance"), dict), "native CLI observation has no provenance")
    root = results[0]["provenance"].get("installed_app")
    require(isinstance(root, str) and root.startswith("/"), "native CLI observation has no installed root")
    require(probe["installation"]["root"] in {ROOT_TOKEN, root}, "native CLI probe root differs from observed installation")
    return bound_probe(pathlib.Path(root))


def load_json(repository: pathlib.Path, relative: str) -> tuple[dict[str, Any], dict[str, Any]]:
    raw = read_bounded_repository_bytes(repository, relative, label="native CLI provenance", maximum_bytes=4 * 1024 * 1024, budget=BoundedReadBudget(4 * 1024 * 1024, "native CLI provenance"))
    return decode_strict_json_object(raw, label="native CLI provenance"), {"path": relative, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}


def record(repository: pathlib.Path, evidence_id: str, kind: str, *, exits: set[int]) -> tuple[dict[str, Any], dict[str, Any]]:
    require(isinstance(evidence_id, str) and re.fullmatch(r"EVID-[A-Za-z0-9_-]{1,128}", evidence_id) is not None, "native CLI provenance evidence ID is invalid")
    relative = f".forge-codex/evidence/{evidence_id}.json"
    result, binding = load_json(repository, relative)
    state, _ = load_json(repository, ".forge-codex/state/run-state.json")
    require(relative in state.get("evidence", []) or evidence_id in state.get("evidence", []), "native CLI provenance record is absent from the ledger")
    require(result.get("schema_version") == 2 and result.get("id") == evidence_id and result.get("kind") == kind, "native CLI provenance recorder identity differs")
    require(type(result.get("exit_code")) is int and result["exit_code"] in exits and result.get("timed_out") is False and result.get("stream_limit_exceeded") is False, "native CLI provenance command failed or exceeded capture bounds")
    require(result.get("artifact_capture_errors") == [] and result.get("ledger_reference") == {"status": "recorded", "exit_code": 0}, "native CLI provenance has missing artifacts or ledger receipt")
    manifest = source_manifest(repository)
    require(result.get("source_manifest") == manifest and result.get("source_manifest_after") == manifest and result.get("source_manifest_changed") is False, "native CLI provenance source manifest is stale or changed")
    validate_source_candidate(repository, result.get("execution_provenance", {}).get("repository", {}).get("head_sha"), current_git_head(repository), result.get("source_manifest"), manifest)
    require(result.get("environment", {}).get("cwd") == str(repository), "native CLI provenance repository differs")
    require(result.get("related_gates") == ["G10"] and result.get("maximum_stream_bytes") == 67108864, "native CLI provenance recorder bounds or gate differ")
    started, ended = datetime.fromisoformat(result.get("started_at", "")), datetime.fromisoformat(result.get("ended_at", ""))
    require(started.tzinfo is not None and ended.tzinfo is not None and 0 <= (ended - started).total_seconds() <= 3600, "native CLI provenance recorder timing differs")
    # Bind preserved command streams too; a status row is not command evidence.
    for suffix in ("stdout", "stderr"):
        path = f".forge-codex/evidence/{evidence_id}.{suffix}.txt"
        artifacts = [a for a in result.get("artifacts", []) if isinstance(a, dict) and a.get("path") == path]
        require(len(artifacts) == 1, "native CLI provenance has no unique command stream")
        raw = read_bounded_repository_bytes(repository, path, label="native CLI command stream", maximum_bytes=64 * 1024 * 1024, budget=BoundedReadBudget(64 * 1024 * 1024, "native CLI command stream"))
        require(artifacts[0].get("bytes") == len(raw) and artifacts[0].get("sha256") == hashlib.sha256(raw).hexdigest(), "native CLI provenance command stream changed")
    return result, binding


def build_application(repository: pathlib.Path, build: dict[str, Any]) -> pathlib.Path:
    argv = shlex.split(build.get("command", ""))
    require(argv and argv[0] in {"xcodebuild", "/usr/bin/xcodebuild"} and argv[-1] == "build", "native CLI build did not invoke ordinary xcodebuild build")
    flags: dict[str, str] = {}
    settings: dict[str, str] = {}
    index = 1
    while index < len(argv) - 1:
        token = argv[index]
        if token.startswith("-"):
            require(token in {"-workspace", "-project", "-scheme", "-configuration", "-destination", "-derivedDataPath", "-resultBundlePath", "-jobs", "-enableAddressSanitizer", "-enableThreadSanitizer", "-enableUndefinedBehaviorSanitizer"} and token not in flags and index + 1 < len(argv) - 1, "native CLI build contains an unreviewed/duplicate option")
            flags[token] = argv[index + 1]
            index += 2
        else:
            require("=" in token, "native CLI build contains an unreviewed action")
            key, value = token.split("=", 1)
            require(key not in settings, "native CLI build contains a duplicate setting")
            settings[key] = value
            index += 1
    require((flags.get("-workspace") == "ForgeConductor.xcworkspace" and "-project" not in flags) or (flags.get("-project") == "ForgeConductor.xcodeproj" and "-workspace" not in flags), "native CLI build did not use the canonical native project")
    require(flags.get("-scheme") == "ForgeConductor" and flags.get("-configuration") == "Release" and flags.get("-destination") in {"platform=macOS,arch=arm64", "platform=macOS,arch=x86_64"}, "native CLI build configuration or scheme is not exact")
    require(all(flags.get(key) == "NO" for key in ("-enableAddressSanitizer", "-enableThreadSanitizer", "-enableUndefinedBehaviorSanitizer")), "native CLI ordinary build must explicitly disable sanitizers")
    require(settings == {"DEVELOPMENT_TEAM": "9AQ2C2838M", "CODE_SIGN_IDENTITY": "Apple Development", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "FORGE_DEVELOPMENT_SIGNING", "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES", "GCC_TREAT_WARNINGS_AS_ERRORS": "YES"}, "native CLI build does not have the exact development Release identity")
    directory = pathlib.Path(flags.get("-derivedDataPath", ""))
    require(directory.is_absolute() and directory.resolve(strict=True) == directory, "native CLI build data path is not canonical")
    app = directory / "Build/Products/Release/Forge Conductor.app"
    require(app.resolve(strict=True) == app, "native CLI build app path is not canonical")
    for relative in BUILD_FILES:
        path = app / relative
        require(path.resolve(strict=True) == path, "native CLI build artifact path changed or is an alias")
        matching = [a for a in build.get("artifacts", []) if isinstance(a, dict) and a.get("path") == str(path)]
        require(len(matching) == 1 and matching[0].get("storage") == "external-hash-only" and matching[0].get("portability") == "origin-host-required", "native CLI build did not capture every exact product artifact")
        current = cli.file_binding(path)
        require(matching[0].get("sha256") == current["sha256"] and matching[0].get("bytes") == current["bytes"], "native CLI build product bytes changed")
    return app


def checked_bundle(repository: pathlib.Path, app: pathlib.Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="forge-cli-identity-") as temporary:
        root = pathlib.Path(temporary)
        argv = [str(repository / ".forge-codex/scripts/check_privileged_filesystem_bundle.sh"), str(app), "DevelopmentRelease"]
        code, timeout, truncated = execute_command(argv, repository, root / "stdout", root / "stderr", 45, 65536, {"PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL":"C", "LANG":"C"})
        require(code == 0 and not timeout and not truncated, "native CLI ordinary development bundle/signature check failed")
    try:
        signature = validate_application_bundle(app, expected_team="9AQ2C2838M")
    except QualificationError as error:
        raise EvidenceSupportError(str(error)) from error
    require(signature.get("signing_authority", "").startswith("Apple Development:"), "native CLI signing class is not Apple Development")
    version, _ = cli.source_version(repository)
    source = (repository / cli.SOURCE_VERSION_PATH).read_text()
    builds = re.findall(r'public static let productBuildVersion = "([1-9][0-9]*)"', source)
    require(len(builds) == 1 and signature.get("version") == version and signature.get("build") == builds[0], "native CLI installed version/build is not current source identity")
    return signature


def provenance(repository: pathlib.Path, build_id: str, installation_id: str) -> dict[str, Any]:
    build, build_binding = record(repository, build_id, "p10-native-cli-build", exits={0})
    source_app = build_application(repository, build)
    installer, install_binding = record(repository, installation_id, "p10-native-cli-installation", exits={0, 4})
    report_artifacts = [a for a in installer.get("artifacts", []) if isinstance(a, dict) and a.get("source_path") == INSTALL_REPORT and a.get("storage") == "evidence-id-specific-copy"]
    require(len(report_artifacts) == 1, "native CLI installation has no unique preserved installer report")
    artifact = report_artifacts[0]
    require(re.fullmatch(re.escape(f".forge-codex/evidence/{installation_id}.artifact-") + r"[0-9]{3}-P10-cli-installation\.json", artifact.get("path", "")) is not None, "native CLI installer report is not evidence-specific")
    report, report_binding = load_json(repository, artifact["path"])
    require(report_binding["sha256"] == artifact.get("sha256") and report_binding["bytes"] == artifact.get("bytes"), "native CLI installer report binding changed")
    require(report.get("kind") == "signed-shell-installed-manager-qualification" and report.get("schema_version") == 1 and report.get("mode") == "execute", "native CLI installation is not an executed supported installer")
    require((installer["exit_code"], report.get("overall_status")) in {(0, "passed"), (4, "partial")}, "native CLI installation did not complete its recorded scope")
    cleanup = report.get("cleanup", {})
    require(cleanup.get("status") == "restored" and cleanup.get("residuals") == [] and cleanup.get("final_canonical_job") == "absent" and cleanup.get("final_canonical_plist") == "absent", "native CLI installation did not restore shared state")
    home = pathlib.Path(cleanup.get("qualification_home_retained", ""))
    require(home.is_absolute() and home.resolve(strict=True) == home, "native CLI installed home is not canonical and retained")
    app = home / "Forge Conductor.app"
    require(app != source_app and app.resolve(strict=True) == app, "native CLI was not exercised from its installed app")
    expected_command = ["python3", ".forge-codex/scripts/qualify_signed_shell_manager.py", "--app", str(source_app), "--execute", "--qualification-home", str(home), "--output", INSTALL_REPORT]
    require(shlex.split(installer.get("command", "")) == expected_command, "native CLI installation did not run the exact reviewed installer command")
    scenario = report.get("scenario", {})
    install = scenario.get("install", {})
    require(install.get("status") == "passed" and type(install.get("exit_code")) is int and install["exit_code"] == 0 and install.get("command") == sandboxed_install_command(source_app / "Contents/Helpers/forge-conductor", home), "native CLI product installation failed or used another executable")
    require(datetime.fromisoformat(build["ended_at"]) <= datetime.fromisoformat(installer["started_at"]), "native CLI installation predates its build")
    source_identity = checked_bundle(repository, source_app)
    installed_identity = checked_bundle(repository, app)
    require(report.get("source_application") == source_identity, "native CLI source identity differs from its installer report")
    require(scenario.get("staged_artifacts", {}).get("application") == installed_identity, "native CLI installed identity differs from its installer report")
    source_files, installed_files = {}, {}
    for relative in BUILD_FILES:
        source_files[relative] = cli.file_binding(source_app / relative)
        installed_files[relative] = cli.file_binding(app / relative)
        # The installer may update the outer app plist; all executable/library
        # bytes and the daemon job definition must remain the recorded build.
        if relative != "Contents/Info.plist":
            require(source_files[relative] == installed_files[relative], "native CLI installed executable/framework differs from the recorded build")
    return {"scope": SCOPE, "distribution_qualified": False, "build_evidence_id": build_id, "installation_evidence_id": installation_id, "build_record": build_binding, "installation_record": install_binding, "build_timing": {key: build[key] for key in ("started_at", "ended_at")}, "installation_timing": {key: installer[key] for key in ("started_at", "ended_at")}, "installation_report": report_binding, "source_app": str(source_app), "installed_app": str(app), "source_files": source_files, "installed_files": installed_files, "source_identity": source_identity, "installed_identity": installed_identity}


def validate_result(repository: pathlib.Path, result: Any, *, evidence_id: str, nonce: str, process: Any) -> bool:
    try:
        require(isinstance(result, dict) and set(result) == {"selector", "evidence_kind", "challenge_nonce", "provenance", "transcript"}, "native CLI result shape differs")
        require(result["selector"] == "cli.version-help" and result["evidence_kind"] == "native-cli-version-help" and result["challenge_nonce"] == nonce, "native CLI result identity differs")
        proof = result["provenance"]
        require(proof == provenance(repository, proof["build_evidence_id"], proof["installation_evidence_id"]), "native CLI lineage binding changed")
        transcript = result["transcript"]
        executable = str(pathlib.Path(proof["installed_app"]) / "Contents/Helpers/forge-conductor")
        version, version_binding = cli.source_version(repository)
        require(transcript.get("kind") == "p10-cli-version-help-supporting-observations" and transcript.get("evidence_id") == evidence_id and transcript.get("challenge_nonce") == nonce and transcript.get("app_path") == proof["installed_app"], "native CLI transcript context differs")
        require(transcript.get("expected_version") == version and transcript.get("version_source") == version_binding, "native CLI transcript source version differs")
        require(transcript.get("bundle_before") == transcript.get("bundle_after") == cli.bundle_manifest(pathlib.Path(proof["installed_app"])), "native CLI bundle or framework changed during capture")
        require(transcript.get("cleanup") == {"temporary_home_removed": True} and transcript.get("isolated_home_unchanged") is True, "native CLI read-only cleanup was not observed")
        require(transcript.get("schema_version") == 1 and transcript.get("candidate_assertion_id") == FEATURE_ID + ".production-path" and transcript.get("accepted_p10_assertions") == [] and transcript.get("artifact_origin") == "embedded-app" and transcript.get("failures") == [], "native CLI raw transcript scope changed")
        require(all(transcript.get(field) is False for field in ("installation_assessed", "signing_assessed", "build_provenance_assessed", "configuration_assessed")), "native CLI raw capture inflated its evidence scope")
        require(transcript.get("bundle_version") == version and transcript.get("bundle_build") == proof["installed_identity"]["build"], "native CLI transcript bundle identity changed")
        started, ended = datetime.fromisoformat(transcript["started_at"]), datetime.fromisoformat(transcript["ended_at"])
        require(started.tzinfo is not None and ended.tzinfo is not None and 0 <= (ended - started).total_seconds() <= 100, "native CLI transcript timing changed")
        cases = transcript.get("cases", [])
        require(isinstance(cases, list) and not cli.validate_cases(cases, executable=executable, version=version), "native CLI semantic command assertions failed")
        require(datetime.fromisoformat(proof["installation_timing"]["ended_at"]) <= started, "native CLI capture predates its recorded installation")
        prior_end = started
        for case in cases:
            case_start, case_end = datetime.fromisoformat(case["started_at"]), datetime.fromisoformat(case["ended_at"])
            require(prior_end <= case_start <= case_end <= ended, "native CLI subprocess timing is not sequential and contained")
            prior_end = case_end
        require(len({case["pid"] for case in cases}) == len(cases), "native CLI subprocess IDs repeat")
        require(process == {"pid": transcript["cases"][0]["pid"], "artifact_id": "forge-conductor-cli", "executable_path": executable}, "native CLI process is not its captured short-lived child")
        return True
    except (OSError, ValueError, KeyError, TypeError, EvidenceSupportError):
        return False


def capture_result(repository: pathlib.Path, *, build_id: str, installation_id: str, evidence_id: str, nonce: str) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    proof = provenance(repository, build_id, installation_id)
    app = pathlib.Path(proof["installed_app"])
    summary = cli.capture(repository, app, evidence_id=evidence_id, challenge_nonce=nonce)
    require(summary["passed"] is True, "native CLI semantic capture failed: " + "; ".join(summary["failures"]))
    transcript, _ = load_json(repository, cli.OBSERVATION_PATH)
    result = {"selector": "cli.version-help", "evidence_kind": "native-cli-version-help", "challenge_nonce": nonce, "provenance": proof, "transcript": transcript}
    process = {"pid": transcript["cases"][0]["pid"], "artifact_id": "forge-conductor-cli", "executable_path": str(app / "Contents/Helpers/forge-conductor")}
    require(validate_result(repository, result, evidence_id=evidence_id, nonce=nonce, process=process), "native CLI observed facts failed independent revalidation")
    return bound_probe(app), result, process
