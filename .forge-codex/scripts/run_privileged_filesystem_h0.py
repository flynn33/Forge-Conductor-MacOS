#!/usr/bin/env python3
"""Preflight and execute the nonshipping privileged-filesystem H0 controls."""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import datetime
import hashlib
import json
import math
import os
import pathlib
import platform
import plistlib
import pwd
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any, Callable, Mapping

from evidence_support import EvidenceSupportError, source_manifest as evidence_source_manifest


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_ROOT.parents[1]
PROTOCOL_SOURCE = (
    REPOSITORY_ROOT / "Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift"
)
QUALIFICATION_TEMPLATE = (
    REPOSITORY_ROOT
    / ".forge-codex/templates/p10-privileged-filesystem-qualification-report.json"
)
CANONICAL_QUALIFICATION_REPORT = (
    REPOSITORY_ROOT
    / ".forge-codex/evidence/P10-privileged-filesystem-qualification-report.json"
)
READINESS_SCHEMA = (
    REPOSITORY_ROOT
    / ".forge-codex/schemas/p10-privileged-filesystem-h0-readiness.schema.json"
)

HARNESS_IDENTIFIER = "com.forge-conductor.qualification-harness"
ADVERSARY_IDENTIFIER = "com.forge-conductor.qualification-adversary"
EXPECTED_IDENTIFIERS = {
    "harness": HARNESS_IDENTIFIER,
    "adversary": ADVERSARY_IDENTIFIER,
}
EXPECTED_COMMANDS = ["describe", "self-check"]
COMPLETION_CLAIM_KEYS = {"e2", "p10", "g10", "g12", "release"}
READINESS_KEYS = {
    "schema_version",
    "command",
    "role",
    "process_id",
    "parent_process_id",
    "effective_user_id",
    "executable_path",
    "bundle_identifier",
    "signing_team_identifier",
    "signing_entitlements",
    "code_directory_hash",
    "hardened_runtime",
    "self_identity_requirement_satisfied",
    "daemon_client_requirement_sha256",
    "daemon_client_requirement_satisfied",
    "team_only_admission_probe_satisfied",
    "recorder_context_present",
    "supported_commands",
    "production_mutation_exercised",
    "qualification_status",
    "rows_updated",
    "formal_predicates_updated",
    "completion_claims",
}
RECORDER_CONTEXT_ENVIRONMENT_KEY = "FORGE_FILESYSTEM_H0_RECORDER_CONTEXT"
START_SUSPENDED_ENVIRONMENT_KEY = "FORGE_FILESYSTEM_H0_START_SUSPENDED"
RECORDER_EVIDENCE_ENVIRONMENT_KEYS = frozenset({
    "FORGE_EVIDENCE_ARCHITECTURE",
    "FORGE_EVIDENCE_BASE_BRANCH",
    "FORGE_EVIDENCE_BASE_SHA",
    "FORGE_EVIDENCE_BINDING_SCHEMA_VERSION",
    "FORGE_EVIDENCE_CONTEXT_SCHEMA_VERSION",
    "FORGE_EVIDENCE_ID",
    "FORGE_EVIDENCE_MACOS_BUILD",
    "FORGE_EVIDENCE_MACHINE_IDENTIFIER",
    "FORGE_EVIDENCE_PLATFORM",
    "FORGE_EVIDENCE_REPOSITORY_BRANCH",
    "FORGE_EVIDENCE_REPOSITORY_HEAD_SHA",
    "FORGE_EVIDENCE_REPOSITORY_PATH",
    "FORGE_EVIDENCE_SOURCE_MANIFEST_JSON",
})
CS_OPS_CDHASH = 5
CS_CDHASH_BYTES = 20
MNT_LOCAL = 0x00001000
EXPECTED_SIGNING_FILESYSTEM = "apfs"
MAXIMUM_TOOL_JSON_BYTES = 16 * 1024
MAXIMUM_RECORDER_CONTEXT_BYTES = 4 * 1024
MAXIMUM_COMMAND_OUTPUT_BYTES = 64 * 1024
MAXIMUM_SOURCE_BYTES = 128 * 1024
MAXIMUM_TEMPLATE_BYTES = 1024 * 1024
MAXIMUM_EXECUTABLE_BYTES = 128 * 1024 * 1024
MAXIMUM_REPORT_BYTES = 1024 * 1024
MAXIMUM_COMMAND_TIMEOUT_SECONDS = 60.0
PROCESS_TERMINATION_GRACE_SECONDS = 0.5
EXPECTED_QUALIFICATION_TEMPLATE_SHA256 = (
    "630f65120eda7cc2fbaea646c9df4772564d1ef9fad1d8aac2577f8e095eb7b3"
)
DEVELOPMENT_CERTIFICATE_REQUIREMENT = (
    "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
)
DISTRIBUTION_CERTIFICATE_REQUIREMENT = (
    "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
)
EXPECTED_MATRIX_KEYS = frozenset({
    "acknowledgement_authority_and_idempotency",
    "acknowledgement_crash_cleanup_matrix",
    "app_manager_cli_helper_packaging",
    "approval_and_denial",
    "atomic_swap_parent_after_capture",
    "atomic_swap_parent_before_capture",
    "atomic_swap_rollback_destination_occupied",
    "atomic_swap_source_leaf_after_capture",
    "atomic_swap_source_leaf_before_capture",
    "atomic_swap_source_leaf_during_capture",
    "atomic_swap_special_leaf_before_descriptor_open",
    "authorization_metadata_change_after_final_check",
    "authorized_app_and_manager_cli_identities",
    "broker_interruption_requires_transaction_recovery",
    "caller_ledger_lock_replacement_during_retention",
    "caller_ledger_precedes_xpc_submission",
    "caller_ledger_restart_and_scope_fencing",
    "caller_ledger_same_uid_tamper",
    "caller_sealed_helper_code_identity",
    "case_normalized_transaction_replay",
    "crash_at_every_durable_phase",
    "cross_volume_destination_durable_before_source_destruction",
    "daemon_restart_and_idempotent_recovery",
    "differently_signed_client",
    "external_volume_rejected",
    "hard_link_behavior",
    "ignore_ownership_volume_rejected",
    "local_ownership_enforced_apfs",
    "manager_restart_and_idempotent_recovery",
    "negative_project_generation_wire_rejected",
    "network_volume_rejected",
    "no_same_uid_fallback",
    "outside_root_sentinel_preservation",
    "parent_relocation_during_rollback",
    "project_binding_hash_collision_resolution",
    "project_binding_lifecycle_exhaustion_and_revoke",
    "project_generation_reset_with_retained_transaction",
    "query_is_strictly_nonmutating",
    "removable_volume_rejected",
    "resume_after_reply_and_pathname_loss",
    "root_descriptor_identity_mismatch",
    "same_connection_service_version_handshake",
    "settings_status_and_control",
    "shell_nonregression",
    "signed_debug_bundle",
    "signed_release_bundle",
    "source_leaf_substitution",
    "stale_project_generation",
    "tampered_or_wrong_signature",
    "terminal_outcome_retained_until_acknowledged",
    "unauthorized_same_uid_client",
    "unauthorized_same_uid_ledger_mutation",
    "unauthorized_same_uid_namespace_access",
    "unknown_protocol_and_malformed_messages",
    "upgrade_unregister_reregister",
    "writable_file_descriptor_behavior",
    "wrong_project_id",
})
EXPECTED_FORMAL_PREDICATE_KEYS = frozenset({
    "caller_generation_fence",
    "capture_linearization",
    "content_exact_fail_closed",
    "current_entry_contract",
    "equivalent_identity_conditional_boundary_proof",
    "final_authorization_metadata_race_closure",
    "namespace_exact_no_mismatch_disposal",
    "protected_namespace_denial",
    "quarantine_disposition_qualification",
    "source_parent_containment_and_authority",
    "startup_recovery_fence",
    "volume_behavior_qualification",
})
EXPECTED_TEMPLATE_KEYS = frozenset({
    "schema_version",
    "artifact_binding_schema_version",
    "status",
    "ok",
    "source_manifest",
    "captured_at",
    "repository",
    "test_environment",
    "test_processes",
    "qualification_context_artifact_reference",
    "matrix",
    "same_uid_fallback",
    "same_uid_threat_model",
    "formal_closure",
    "residual_risk",
    "remaining_requirements",
})
EXPECTED_MATRIX_ROW_KEYS = frozenset({
    "contracts_exercised",
    "status",
    "raw_artifact_references",
    "iterations",
    "barrier_evidence",
    "process_identities",
    "signing_identities",
    "fixture_digests",
    "mount_facts",
    "crash_point",
    "observed_result",
})
EXPECTED_REPOSITORY_TEMPLATE = {
    "branch": None,
    "head_sha": None,
    "base_branch": None,
    "base_sha": None,
    "repository_path": None,
}
EXPECTED_TEST_ENVIRONMENT_TEMPLATE = {
    "macos_build": None,
    "machine_identifier": None,
    "platform": None,
    "architecture": None,
}
EXPECTED_MOUNT_FACTS_TEMPLATE = {
    "applicable": False,
    "filesystem_type": None,
    "mount_path": None,
    "device_identifier": None,
    "volume_uuid": None,
    "mount_flags": [],
    "local": None,
    "removable": None,
    "network": None,
    "ownership_enabled": None,
    "raw_artifact_reference": None,
}
EXPECTED_CRASH_POINT_TEMPLATE = {
    "applicable": False,
    "phase": None,
    "timing": None,
    "signal": None,
    "restart_observed": None,
    "raw_artifact_reference": None,
}


class H0Error(RuntimeError):
    """An H0 control invariant was not established."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise H0Error(message)


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def bounded_text(value: bytes, maximum: int = 4_000) -> str:
    decoded = value.decode("utf-8", errors="replace")
    return decoded if len(decoded) <= maximum else decoded[-maximum:]


@dataclasses.dataclass(frozen=True)
class FileSnapshot:
    path: str
    device: int
    inode: int
    mode: int
    owner_uid: int
    link_count: int
    size: int
    modification_time_ns: int
    change_time_ns: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class BoundedCommandResult:
    arguments: tuple[str, ...]
    pid: int
    returncode: int
    stdout: bytes
    stderr: bytes
    timed_out: bool
    process_group_cleanup: str


class DarwinFSID(ctypes.Structure):
    _fields_ = [("value", ctypes.c_int32 * 2)]


class DarwinStatFS(ctypes.Structure):
    _fields_ = [
        ("f_bsize", ctypes.c_uint32),
        ("f_iosize", ctypes.c_int32),
        ("f_blocks", ctypes.c_uint64),
        ("f_bfree", ctypes.c_uint64),
        ("f_bavail", ctypes.c_uint64),
        ("f_files", ctypes.c_uint64),
        ("f_ffree", ctypes.c_uint64),
        ("f_fsid", DarwinFSID),
        ("f_owner", ctypes.c_uint32),
        ("f_type", ctypes.c_uint32),
        ("f_flags", ctypes.c_uint32),
        ("f_fssubtype", ctypes.c_uint32),
        ("f_fstypename", ctypes.c_char * 16),
        ("f_mntonname", ctypes.c_char * 1024),
        ("f_mntfromname", ctypes.c_char * 1024),
        ("f_flags_ext", ctypes.c_uint32),
        ("f_reserved", ctypes.c_uint32 * 7),
    ]


def snapshot_regular_file(
    path: pathlib.Path,
    *,
    label: str,
    maximum_bytes: int,
    executable: bool = False,
) -> FileSnapshot:
    require(path.is_absolute(), f"{label} path must be absolute: {path}")
    try:
        before = path.lstat()
    except OSError as error:
        raise H0Error(f"cannot inspect {label}: {path}: {error}") from error
    require(not stat.S_ISLNK(before.st_mode), f"{label} must not be a symlink: {path}")
    require(stat.S_ISREG(before.st_mode), f"{label} must be a regular file: {path}")
    require(before.st_nlink > 0, f"{label} has no filesystem link: {path}")
    require(before.st_size <= maximum_bytes, f"{label} exceeds its byte bound: {path}")
    if executable:
        require(os.access(path, os.X_OK), f"{label} is not executable: {path}")

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise H0Error(f"cannot open {label}: {path}: {error}") from error
    digest = hashlib.sha256()
    count = 0
    try:
        opened = os.fstat(descriptor)
        require(
            (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} changed before its bounded read: {path}",
        )
        while True:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - count))
            if not block:
                break
            count += len(block)
            require(count <= maximum_bytes, f"{label} exceeds its byte bound: {path}")
            digest.update(block)
        after_read = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after_lookup = path.lstat()
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_uid",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    require(
        all(getattr(before, field) == getattr(after_read, field) for field in stable_fields)
        and all(getattr(before, field) == getattr(after_lookup, field) for field in stable_fields),
        f"{label} changed during its bounded read: {path}",
    )
    require(count == before.st_size, f"{label} byte count changed during read: {path}")
    return FileSnapshot(
        path=str(path),
        device=before.st_dev,
        inode=before.st_ino,
        mode=stat.S_IMODE(before.st_mode),
        owner_uid=before.st_uid,
        link_count=before.st_nlink,
        size=before.st_size,
        modification_time_ns=before.st_mtime_ns,
        change_time_ns=before.st_ctime_ns,
        sha256=digest.hexdigest(),
    )


def require_unchanged(before: FileSnapshot, after: FileSnapshot, label: str) -> None:
    require(before == after, f"{label} changed during H0 execution: {before.path}")


def qualified_signing_filesystem(path: pathlib.Path) -> dict[str, Any]:
    """Require the filesystem semantics used by H0 path-replacement detection."""
    require(platform.system() == "Darwin", "H0 signing controls require macOS")
    require(path.is_absolute(), "signing filesystem path must be absolute")
    encoded = os.fsencode(path)
    require(b"\0" not in encoded, "signing filesystem path contains NUL")
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        statfs = libc.statfs
    except AttributeError as error:
        raise H0Error("statfs is unavailable for signing-filesystem qualification") from error
    statfs.argtypes = [ctypes.c_char_p, ctypes.POINTER(DarwinStatFS)]
    statfs.restype = ctypes.c_int
    value = DarwinStatFS()
    if statfs(encoded, ctypes.byref(value)) != 0:
        code = ctypes.get_errno()
        raise H0Error(f"cannot inspect signing filesystem for {path}: errno {code}")

    def decode_field(raw: bytes, label: str) -> str:
        try:
            decoded = raw.split(b"\0", 1)[0].decode("utf-8")
        except UnicodeDecodeError as error:
            raise H0Error(f"signing filesystem returned invalid {label}") from error
        require(decoded != "", f"signing filesystem returned empty {label}")
        return decoded

    filesystem_type = decode_field(bytes(value.f_fstypename), "type")
    mount_point = decode_field(bytes(value.f_mntonname), "mount point")
    mount_source = decode_field(bytes(value.f_mntfromname), "mount source")
    local = bool(value.f_flags & MNT_LOCAL)
    require(
        filesystem_type == EXPECTED_SIGNING_FILESYSTEM,
        f"signing executable is not on qualified APFS storage: {path}",
    )
    require(local, f"signing executable is not on qualified local storage: {path}")
    require(mount_point.startswith("/"), "signing filesystem mount point is not absolute")
    return {
        "type": filesystem_type,
        "local": local,
        "mount_point": mount_point,
        "mount_source": mount_source,
        "mount_flags": int(value.f_flags),
        "identity_replacement_detection": "inode_and_ctime_on_local_apfs",
    }


def read_bounded_regular_bytes(
    path: pathlib.Path,
    *,
    label: str,
    maximum_bytes: int,
) -> tuple[FileSnapshot, bytes]:
    before = snapshot_regular_file(
        path,
        label=label,
        maximum_bytes=maximum_bytes,
    )
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise H0Error(f"cannot reopen {label}: {path}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        require(
            (opened.st_dev, opened.st_ino) == (before.device, before.inode),
            f"{label} changed before content capture: {path}",
        )
        chunks: list[bytes] = []
        count = 0
        while True:
            block = os.read(descriptor, min(64 * 1024, maximum_bytes + 1 - count))
            if not block:
                break
            count += len(block)
            require(count <= maximum_bytes, f"{label} exceeds its byte bound: {path}")
            chunks.append(block)
    finally:
        os.close(descriptor)
    captured = b"".join(chunks)
    require(len(captured) == before.size, f"{label} byte count changed during capture: {path}")
    require(sha256_bytes(captured) == before.sha256, f"{label} bytes changed during capture: {path}")
    after = snapshot_regular_file(
        path,
        label=label,
        maximum_bytes=maximum_bytes,
    )
    require_unchanged(before, after, label)
    return before, captured


def strict_json_object(data: bytes, *, label: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise H0Error(f"{label} contains duplicate key: {key}")
            result[key] = value
        return result

    try:
        decoded = data.decode("utf-8")
        value = json.loads(decoded, object_pairs_hook=reject_duplicates)
    except UnicodeDecodeError as error:
        raise H0Error(f"{label} is not UTF-8") from error
    except json.JSONDecodeError as error:
        raise H0Error(f"{label} is malformed JSON") from error
    require(isinstance(value, dict), f"{label} root is not an object")
    return value


def validate_nonpassing_qualification_template(
    path: pathlib.Path,
) -> tuple[FileSnapshot, dict[str, Any]]:
    snapshot, captured = read_bounded_regular_bytes(
        path,
        label="canonical qualification template",
        maximum_bytes=MAXIMUM_TEMPLATE_BYTES,
    )
    value = strict_json_object(captured, label="canonical qualification template")
    require(set(value) == EXPECTED_TEMPLATE_KEYS, "qualification template fields changed")
    require(
        type(value["schema_version"]) is int and value["schema_version"] == 2,
        "qualification template schema changed",
    )
    require(
        type(value["artifact_binding_schema_version"]) is int
        and value["artifact_binding_schema_version"] == 1,
        "qualification artifact-binding schema changed",
    )
    require(value["status"] == "partial", "qualification template is not partial")
    require(value["ok"] is False, "qualification template claims success")
    for field in ("source_manifest", "captured_at", "qualification_context_artifact_reference"):
        require(value[field] is None, f"qualification template binds {field}")
    require(
        value["repository"] == EXPECTED_REPOSITORY_TEMPLATE,
        "qualification template binds repository identity",
    )
    require(
        value["test_environment"] == EXPECTED_TEST_ENVIRONMENT_TEMPLATE,
        "qualification template binds test environment",
    )
    require(
        value["test_processes"]
        == {"separately_signed": False, "helper_effective_uid": None},
        "qualification template claims signed test processes",
    )
    require(value["same_uid_fallback"] == "unverified", "same-UID fallback was advanced")
    require(value["same_uid_threat_model"] == "in_scope", "same-UID threat model changed")

    matrix = value["matrix"]
    require(isinstance(matrix, dict), "qualification matrix is not an object")
    require(set(matrix) == EXPECTED_MATRIX_KEYS, "qualification matrix keys changed")
    for case_id, row in matrix.items():
        require(isinstance(row, dict), f"qualification row is invalid: {case_id}")
        require(set(row) == EXPECTED_MATRIX_ROW_KEYS, f"qualification row fields changed: {case_id}")
        require(row["status"] == "not_run", f"qualification row was advanced: {case_id}")
        contracts = row["contracts_exercised"]
        require(
            isinstance(contracts, list)
            and contracts
            and all(isinstance(item, str) and item for item in contracts),
            f"qualification row contracts are invalid: {case_id}",
        )
        require(row["raw_artifact_references"] == [], f"row has artifacts: {case_id}")
        require(row["barrier_evidence"] == [], f"row has barrier evidence: {case_id}")
        require(row["process_identities"] == [], f"row has process identity: {case_id}")
        require(row["signing_identities"] == [], f"row has signing identity: {case_id}")
        require(
            row["fixture_digests"] == {"before": [], "after": []},
            f"row has fixture evidence: {case_id}",
        )
        iterations = row["iterations"]
        require(
            iterations
            == {
                "planned": 1,
                "executed": 0,
                "conclusive": 0,
                "barrier_hits": 0,
                "barrier_misses": 0,
            },
            f"row iteration facts were advanced: {case_id}",
        )
        require(
            row["mount_facts"] == EXPECTED_MOUNT_FACTS_TEMPLATE,
            f"row has mount evidence: {case_id}",
        )
        require(
            row["crash_point"] == EXPECTED_CRASH_POINT_TEMPLATE,
            f"row has crash evidence: {case_id}",
        )
        require(
            isinstance(row["observed_result"], str)
            and row["observed_result"].startswith("Not executed;"),
            f"row claims an observed result: {case_id}",
        )

    formal = value["formal_closure"]
    require(isinstance(formal, dict), "formal closure is not an object")
    require(
        set(formal) == EXPECTED_FORMAL_PREDICATE_KEYS | {"formal_argument_artifact_references"},
        "formal closure keys changed",
    )
    require(
        all(formal[key] is False for key in EXPECTED_FORMAL_PREDICATE_KEYS),
        "a formal predicate was advanced",
    )
    require(
        formal["formal_argument_artifact_references"] == [],
        "formal argument artifacts were bound",
    )
    residual = value["residual_risk"]
    require(
        isinstance(residual, dict)
        and residual.get("disposition") == "open_release_blocker",
        "residual E2 risk is not an open release blocker",
    )
    remaining = value["remaining_requirements"]
    require(
        isinstance(remaining, list)
        and len(remaining) == 8
        and all(isinstance(item, str) and item for item in remaining),
        "qualification template remaining requirements changed",
    )
    require(
        snapshot.sha256 == EXPECTED_QUALIFICATION_TEMPLATE_SHA256,
        "canonical qualification template digest changed",
    )
    return snapshot, {
        "matrix_rows_required": len(matrix),
        "matrix_rows_executed": 0,
        "formal_predicates_required": len(EXPECTED_FORMAL_PREDICATE_KEYS),
        "formal_predicates_proven": 0,
        "status": "partial",
        "ok": False,
        "residual_disposition": residual["disposition"],
    }


def validate_recorder_evidence_context(
    environment: Mapping[str, str],
    *,
    required: bool,
    repository: Mapping[str, str],
) -> dict[str, Any] | None:
    present = RECORDER_EVIDENCE_ENVIRONMENT_KEYS & set(environment)
    if not present:
        require(not required, "--execute requires recorder-owned evidence context")
        return None
    require(
        present == RECORDER_EVIDENCE_ENVIRONMENT_KEYS,
        "recorder-owned evidence context is incomplete",
    )
    require(
        "FORGE_EVIDENCE_QUALIFICATION" not in environment,
        "H0 readiness must not receive semantic qualification context",
    )

    def bounded(name: str, maximum_bytes: int = 4096) -> str:
        value = environment[name]
        require(
            isinstance(value, str)
            and value
            and "\0" not in value
            and len(value.encode("utf-8")) <= maximum_bytes,
            f"recorder evidence value is invalid: {name}",
        )
        return value

    require(
        bounded("FORGE_EVIDENCE_CONTEXT_SCHEMA_VERSION", 8) == "1",
        "recorder evidence context schema changed",
    )
    require(
        bounded("FORGE_EVIDENCE_BINDING_SCHEMA_VERSION", 8) == "1",
        "recorder evidence binding schema changed",
    )
    evidence_id = bounded("FORGE_EVIDENCE_ID", 256)
    require(
        re.fullmatch(r"EVID-[A-Za-z0-9][A-Za-z0-9._-]{0,250}", evidence_id) is not None,
        "recorder evidence ID is invalid",
    )
    recorder_repository_path = pathlib.Path(
        bounded("FORGE_EVIDENCE_REPOSITORY_PATH")
    )
    require(recorder_repository_path.is_absolute(), "recorder repository path is not absolute")
    require(
        recorder_repository_path.resolve(strict=True) == REPOSITORY_ROOT.resolve(strict=True),
        "recorder repository path does not identify this checkout",
    )
    require(
        bounded("FORGE_EVIDENCE_REPOSITORY_BRANCH", 256) == repository["branch"],
        "recorder branch differs from execution branch",
    )
    require(
        bounded("FORGE_EVIDENCE_REPOSITORY_HEAD_SHA", 64) == repository["head"],
        "recorder HEAD differs from execution HEAD",
    )
    require(
        bounded("FORGE_EVIDENCE_BASE_BRANCH", 256) == repository["base_branch"],
        "recorder base branch differs from execution base",
    )
    require(
        bounded("FORGE_EVIDENCE_BASE_SHA", 64) == repository["base_sha"],
        "recorder base SHA differs from execution base",
    )
    raw_manifest = bounded("FORGE_EVIDENCE_SOURCE_MANIFEST_JSON", 4096).encode("utf-8")
    manifest = strict_json_object(raw_manifest, label="recorder source manifest")
    require(
        raw_manifest
        == json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        "recorder source manifest is not canonical JSON",
    )
    require(
        set(manifest) == {"schema_version", "sha256", "file_count", "bytes"}
        and manifest["schema_version"] == 1
        and isinstance(manifest["sha256"], str)
        and re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"]) is not None
        and type(manifest["file_count"]) is int
        and manifest["file_count"] > 0
        and type(manifest["bytes"]) is int
        and manifest["bytes"] > 0,
        "recorder source manifest is invalid",
    )
    try:
        current_manifest = evidence_source_manifest(REPOSITORY_ROOT)
    except EvidenceSupportError as error:
        raise H0Error(f"cannot recompute recorder source manifest: {error}") from error
    require(manifest == current_manifest, "recorder source manifest differs from current source")

    test_environment = {
        "macos_build": bounded("FORGE_EVIDENCE_MACOS_BUILD", 256),
        "machine_identifier": bounded("FORGE_EVIDENCE_MACHINE_IDENTIFIER", 256),
        "platform": bounded("FORGE_EVIDENCE_PLATFORM"),
        "architecture": bounded("FORGE_EVIDENCE_ARCHITECTURE", 256),
    }
    require(
        test_environment["architecture"] == platform.machine(),
        "recorder architecture differs from the running process",
    )
    return {
        "schema_version": 1,
        "binding_schema_version": 1,
        "evidence_id": evidence_id,
        "source_manifest": manifest,
        "repository": {
            "branch": repository["branch"],
            "head_sha": repository["head"],
            "base_branch": repository["base_branch"],
            "base_sha": repository["base_sha"],
            "repository_path": str(REPOSITORY_ROOT.resolve(strict=True)),
        },
        "test_environment": test_environment,
        "qualification_context_present": False,
    }


def _child_limits(maximum_output_bytes: int, timeout: float) -> None:
    file_limit = maximum_output_bytes + 1
    resource.setrlimit(resource.RLIMIT_FSIZE, (file_limit, file_limit))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    cpu_limit = max(1, int(math.ceil(timeout)) + 1)
    current_soft, current_hard = resource.getrlimit(resource.RLIMIT_CPU)
    if current_hard == resource.RLIM_INFINITY:
        bounded_hard = cpu_limit
    else:
        bounded_hard = min(int(current_hard), cpu_limit)
    if current_soft == resource.RLIM_INFINITY:
        bounded_soft = bounded_hard
    else:
        bounded_soft = min(int(current_soft), bounded_hard)
    resource.setrlimit(resource.RLIMIT_CPU, (bounded_soft, bounded_hard))


def _process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _signal_process_group(process_group_id: int, value: signal.Signals) -> bool:
    try:
        os.killpg(process_group_id, value)
        return True
    except ProcessLookupError:
        return False
    except PermissionError as error:
        raise H0Error(f"cannot signal owned process group {process_group_id}") from error


def _wait_for_process_group_exit(process_group_id: int, deadline: float) -> bool:
    while time.monotonic() < deadline:
        if not _process_group_exists(process_group_id):
            return True
        time.sleep(0.02)
    return not _process_group_exists(process_group_id)


def _reap_process_leader(process: subprocess.Popen[bytes], timeout: float) -> bool:
    if process.returncode is not None:
        return True
    try:
        process.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


def _cleanup_process_group(process: subprocess.Popen[bytes]) -> str:
    process_group_id = process.pid
    _reap_process_leader(process, 0)
    if not _process_group_exists(process_group_id):
        _reap_process_leader(process, PROCESS_TERMINATION_GRACE_SECONDS)
        return "already_empty"
    _signal_process_group(process_group_id, signal.SIGKILL)
    _reap_process_leader(process, PROCESS_TERMINATION_GRACE_SECONDS)
    if _wait_for_process_group_exit(
        process_group_id,
        time.monotonic() + PROCESS_TERMINATION_GRACE_SECONDS,
    ):
        return "killed"
    raise H0Error(f"owned process group {process_group_id} survived SIGKILL")


def minimal_environment(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    temporary = os.environ.get("TMPDIR")
    if temporary:
        environment["TMPDIR"] = temporary
    if extra:
        for key, value in extra.items():
            require(
                isinstance(key, str)
                and isinstance(value, str)
                and "\0" not in key
                and "\0" not in value,
                "subprocess environment contains an invalid entry",
            )
            environment[key] = value
    return environment


def live_process_cdhash(process_id: int) -> str:
    require(process_id > 0, "live process ID is invalid")
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        csops = libc.csops
    except AttributeError as error:
        raise H0Error("csops is unavailable for live process identity binding") from error
    csops.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
    csops.restype = ctypes.c_int
    buffer = (ctypes.c_ubyte * CS_CDHASH_BYTES)()
    result = csops(
        process_id,
        CS_OPS_CDHASH,
        ctypes.byref(buffer),
        CS_CDHASH_BYTES,
    )
    if result != 0:
        code = ctypes.get_errno()
        raise H0Error(f"cannot read live process CDHash for PID {process_id}: errno {code}")
    value = bytes(buffer).hex()
    require(
        re.fullmatch(r"[0-9a-f]{40}", value) is not None and value != "0" * 40,
        "live process returned an invalid CDHash",
    )
    return value


def wait_for_suspended_child(process: subprocess.Popen[bytes], timeout: float) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            waited, wait_status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
        except ChildProcessError as error:
            raise H0Error("qualification child exited before live identity binding") from error
        if waited == 0:
            time.sleep(0.005)
            continue
        if os.WIFSTOPPED(wait_status):
            stop_signal = os.WSTOPSIG(wait_status)
            require(stop_signal == signal.SIGSTOP, "qualification child used an unexpected stop")
            return stop_signal
        process.returncode = os.waitstatus_to_exitcode(wait_status)
        raise H0Error("qualification child exited before live identity binding")
    raise H0Error("qualification child did not enter its bounded identity barrier")


def run_bounded(
    arguments: list[str],
    *,
    timeout: float,
    maximum_output_bytes: int = MAXIMUM_COMMAND_OUTPUT_BYTES,
    environment: Mapping[str, str] | None = None,
    on_started: Callable[[subprocess.Popen[bytes]], None] | None = None,
) -> BoundedCommandResult:
    require(arguments and all(isinstance(item, str) and item for item in arguments), "empty command")
    require(pathlib.Path(arguments[0]).is_absolute(), "subprocess executable must be absolute")
    require(0 < timeout <= MAXIMUM_COMMAND_TIMEOUT_SECONDS, "command timeout is outside bounds")
    require(0 < maximum_output_bytes <= MAXIMUM_COMMAND_OUTPUT_BYTES, "output bound is invalid")
    process: subprocess.Popen[bytes] | None = None
    timed_out = False
    cleanup = "not_started"
    with tempfile.TemporaryDirectory(prefix="forge-filesystem-h0-process-") as temporary:
        root = pathlib.Path(temporary)
        stdout_path = root / "stdout"
        stderr_path = root / "stderr"
        with stdout_path.open("w+b") as stdout_stream, stderr_path.open("w+b") as stderr_stream:
            try:
                process = subprocess.Popen(
                    arguments,
                    stdin=subprocess.DEVNULL,
                    stdout=stdout_stream,
                    stderr=stderr_stream,
                    env=minimal_environment(environment),
                    close_fds=True,
                    start_new_session=True,
                    preexec_fn=lambda: _child_limits(maximum_output_bytes, timeout),
                )
                if on_started is not None:
                    on_started(process)
                try:
                    process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    _signal_process_group(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=PROCESS_TERMINATION_GRACE_SECONDS)
                    except subprocess.TimeoutExpired:
                        _signal_process_group(process.pid, signal.SIGKILL)
                        try:
                            process.wait(timeout=PROCESS_TERMINATION_GRACE_SECONDS)
                        except subprocess.TimeoutExpired as error:
                            raise H0Error(
                                f"subprocess {process.pid} survived bounded SIGKILL"
                            ) from error
            except OSError as error:
                raise H0Error(f"cannot launch bounded command: {arguments[0]}: {error}") from error
            finally:
                if process is not None:
                    active_error = sys.exc_info()[1]
                    try:
                        cleanup = _cleanup_process_group(process)
                    except H0Error as cleanup_error:
                        if active_error is not None:
                            raise H0Error(
                                f"{active_error}; bounded cleanup also failed: {cleanup_error}"
                            ) from active_error
                        raise
            stdout_stream.flush()
            stderr_stream.flush()
            stdout_stream.seek(0)
            stderr_stream.seek(0)
            stdout = stdout_stream.read(maximum_output_bytes + 1)
            stderr = stderr_stream.read(maximum_output_bytes + 1)
    require(process is not None and process.returncode is not None, "subprocess has no terminal status")
    require(len(stdout) <= maximum_output_bytes, "subprocess stdout exceeded its byte bound")
    require(len(stderr) <= maximum_output_bytes, "subprocess stderr exceeded its byte bound")
    return BoundedCommandResult(
        arguments=tuple(arguments),
        pid=process.pid,
        returncode=process.returncode,
        stdout=stdout,
        stderr=stderr,
        timed_out=timed_out,
        process_group_cleanup=cleanup,
    )


def validate_logged_in_user() -> dict[str, Any]:
    require(platform.system() == "Darwin", "H0 signed controls require macOS")
    real_uid = os.getuid()
    effective_uid = os.geteuid()
    require(real_uid > 0 and effective_uid > 0, "H0 controls must run as a non-root user")
    require(real_uid == effective_uid, "H0 controls do not accept a set-user-ID invocation")
    try:
        account = pwd.getpwuid(effective_uid)
    except KeyError as error:
        raise H0Error("effective user has no local account record") from error
    console = run_bounded(
        ["/usr/bin/stat", "-f", "%Su", "/dev/console"],
        timeout=5,
        maximum_output_bytes=1024,
    )
    require(console.returncode == 0 and not console.timed_out, "cannot identify console user")
    require(console.stderr == b"", "console-user lookup emitted diagnostics")
    try:
        console_user = console.stdout.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise H0Error("console-user lookup returned invalid UTF-8") from error
    require(console_user == account.pw_name, "effective user is not the logged-in console user")
    return {"uid": effective_uid, "name": account.pw_name, "console_user": console_user}


def validate_executable_paths(
    harness: pathlib.Path,
    adversary: pathlib.Path,
) -> dict[str, pathlib.Path]:
    validated: dict[str, pathlib.Path] = {}
    snapshots: dict[str, FileSnapshot] = {}
    for role, candidate in (("harness", harness), ("adversary", adversary)):
        require(candidate.is_absolute(), f"{role} executable path must be absolute")
        snapshot = snapshot_regular_file(
            candidate,
            label=f"{role} executable",
            maximum_bytes=MAXIMUM_EXECUTABLE_BYTES,
            executable=True,
        )
        resolved = candidate.resolve(strict=True)
        resolved_snapshot = snapshot_regular_file(
            resolved,
            label=f"resolved {role} executable",
            maximum_bytes=MAXIMUM_EXECUTABLE_BYTES,
            executable=True,
        )
        require(
            (snapshot.device, snapshot.inode) == (resolved_snapshot.device, resolved_snapshot.inode),
            f"{role} executable resolution changed identity",
        )
        validated[role] = resolved
        snapshots[role] = resolved_snapshot
    require(validated["harness"] != validated["adversary"], "H0 executables must be distinct paths")
    require(
        (snapshots["harness"].device, snapshots["harness"].inode)
        != (snapshots["adversary"].device, snapshots["adversary"].inode),
        "H0 executables must be distinct filesystem objects",
    )
    return validated


def _extract_swift_string_constant(source: str, name: str) -> str:
    matches = re.findall(
        rf"public\s+static\s+let\s+{re.escape(name)}\s*=\s*\"([^\"\\]+)\"",
        source,
    )
    require(len(matches) == 1, f"protocol source has no single {name} constant")
    return matches[0]


def read_daemon_client_requirement(
    source_path: pathlib.Path,
    expected_team: str,
) -> dict[str, Any]:
    source_snapshot, source_bytes = read_bounded_regular_bytes(
        source_path,
        label="filesystem protocol source",
        maximum_bytes=MAXIMUM_SOURCE_BYTES,
    )
    try:
        source = source_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise H0Error(f"cannot read filesystem protocol source: {error}") from error
    app_identifier = _extract_swift_string_constant(source, "appIdentifier")
    manager_identifier = _extract_swift_string_constant(source, "managerIdentifier")
    development_team = _extract_swift_string_constant(source, "developmentTeamIdentifier")
    production_team = _extract_swift_string_constant(source, "productionTeamIdentifier")
    app_shape = re.compile(
        r"public\s+static\s+var\s+requiredAppCodeSigningRequirement\s*:\s*String\s*\{\s*"
        r"requirement\s*\(\s*identifier\s*:\s*appIdentifier\s*,\s*"
        r"teamIdentifier\s*:\s*activeTeamIdentifier\s*,\s*"
        r"allowDevelopmentCertificate\s*:\s*isDevelopmentBuild\s*\)\s*\}"
    )
    client_shape = re.compile(
        r"public\s+static\s+var\s+requiredClientCodeSigningRequirement\s*:\s*String\s*\{\s*"
        r"let\s+managerRequirement\s*=\s*requirement\s*\(\s*"
        r"identifier\s*:\s*managerIdentifier\s*,\s*"
        r"teamIdentifier\s*:\s*activeTeamIdentifier\s*,\s*"
        r"allowDevelopmentCertificate\s*:\s*isDevelopmentBuild\s*\)\s*"
        r"return\s+\"\(\\\(requiredAppCodeSigningRequirement\)\)\s+or\s+"
        r"\(\\\(managerRequirement\)\)\"\s*\}"
    )
    require(app_shape.search(source) is not None, "protocol app admission requirement shape changed")
    require(
        client_shape.search(source) is not None,
        "protocol client admission requirement shape changed",
    )
    require(
        DEVELOPMENT_CERTIFICATE_REQUIREMENT in source
        and DISTRIBUTION_CERTIFICATE_REQUIREMENT in source
        and "anchor apple generic and identifier" in source
        and "certificate leaf[subject.OU]" in source,
        "protocol identity-requirement constructor shape changed",
    )
    require(
        HARNESS_IDENTIFIER not in source and ADVERSARY_IDENTIFIER not in source,
        "protocol source unexpectedly names an H0 tool as a client",
    )
    if expected_team == development_team:
        certificate_requirement = DEVELOPMENT_CERTIFICATE_REQUIREMENT
        certificate_class = "development"
        authority_prefix = "Apple Development:"
    elif expected_team == production_team:
        certificate_requirement = DISTRIBUTION_CERTIFICATE_REQUIREMENT
        certificate_class = "distribution"
        authority_prefix = "Developer ID Application:"
    else:
        raise H0Error("expected team is not a protocol-defined development or production team")

    def identity_requirement(identifier: str) -> str:
        return (
            f'anchor apple generic and identifier "{identifier}" '
            f'and certificate leaf[subject.OU] = "{expected_team}" '
            f"and {certificate_requirement}"
        )

    app_requirement = identity_requirement(app_identifier)
    manager_requirement = identity_requirement(manager_identifier)
    return {
        "source": dataclasses.asdict(source_snapshot),
        "app_identifier": app_identifier,
        "manager_identifier": manager_identifier,
        "development_team_identifier": development_team,
        "production_team_identifier": production_team,
        "certificate_class": certificate_class,
        "authority_prefix": authority_prefix,
        "certificate_requirement": certificate_requirement,
        "requirement": f"({app_requirement}) or ({manager_requirement})",
        "requirement_sha256": sha256_bytes(
            f"({app_requirement}) or ({manager_requirement})".encode("utf-8")
        ),
    }


def parse_codesign_details(value: str) -> dict[str, Any]:
    collected: dict[str, list[str]] = {
        "identifier": [],
        "team_identifier": [],
        "cdhash": [],
        "code_directory": [],
        "authorities": [],
    }
    for line in value.splitlines():
        if line.startswith("Identifier="):
            collected["identifier"].append(line.split("=", 1)[1])
        elif line.startswith("TeamIdentifier="):
            collected["team_identifier"].append(line.split("=", 1)[1])
        elif line.startswith("CDHash="):
            collected["cdhash"].append(line.split("=", 1)[1].lower())
        elif line.startswith("Authority="):
            collected["authorities"].append(line.split("=", 1)[1])
        elif "CodeDirectory " in line and " flags=" in line:
            collected["code_directory"].append(line.strip())
    for key in ("identifier", "team_identifier", "cdhash", "code_directory"):
        require(len(collected[key]) == 1, f"codesign returned no single {key}")
    require(collected["authorities"], "codesign returned no signing authorities")
    return {
        "identifier": collected["identifier"][0],
        "team_identifier": collected["team_identifier"][0],
        "cdhash": collected["cdhash"][0],
        "code_directory": collected["code_directory"][0],
        "authorities": collected["authorities"],
    }


def parse_designated_requirement(value: str) -> str:
    requirements: list[str] = []
    for line in value.splitlines():
        match = re.match(r"\s*#?\s*designated\s*=>\s*(.+?)\s*$", line)
        if match:
            requirements.append(match.group(1))
    require(len(requirements) == 1, "codesign returned no single designated requirement")
    require(len(requirements[0].encode("utf-8")) <= 8 * 1024, "designated requirement is oversized")
    return requirements[0]


def parse_entitlements(value: bytes, expected_identifier: str, expected_team: str) -> dict[str, Any]:
    if not value.strip():
        return {}
    require(len(value) <= MAXIMUM_COMMAND_OUTPUT_BYTES, "entitlements output is oversized")
    try:
        entitlements = plistlib.loads(value)
    except plistlib.InvalidFileException as error:
        raise H0Error("codesign returned malformed entitlements") from error
    require(isinstance(entitlements, dict), "entitlements root is not a dictionary")
    allowed_keys = {"com.apple.application-identifier"}
    unexpected = sorted(set(entitlements) - allowed_keys)
    require(not unexpected, f"H0 executable has unexpected entitlements: {unexpected}")
    application_identifier = entitlements.get("com.apple.application-identifier")
    if application_identifier is not None:
        require(
            application_identifier == f"{expected_team}.{expected_identifier}",
            "H0 executable has the wrong application-identifier entitlement",
        )
    return entitlements


def inspect_signature(
    path: pathlib.Path,
    *,
    expected_identifier: str,
    expected_team: str,
    admission: Mapping[str, Any],
    timeout: float,
) -> dict[str, Any]:
    filesystem_before = qualified_signing_filesystem(path)
    before = snapshot_regular_file(
        path,
        label="signed H0 executable",
        maximum_bytes=MAXIMUM_EXECUTABLE_BYTES,
        executable=True,
    )
    certificate_requirement = str(admission["certificate_requirement"])
    own_requirement = (
        f'anchor apple generic and identifier "{expected_identifier}" '
        f'and certificate leaf[subject.OU] = "{expected_team}" '
        f"and {certificate_requirement}"
    )
    verify = run_bounded(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            "--verbose=4",
            str(path),
        ],
        timeout=timeout,
    )
    require(
        verify.returncode == 0 and not verify.timed_out,
        f"code signature validation failed for {path}: {bounded_text(verify.stderr)}",
    )
    exact = run_bounded(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            "--verbose=4",
            f"-R={own_requirement}",
            str(path),
        ],
        timeout=timeout,
    )
    require(
        exact.returncode == 0 and not exact.timed_out,
        f"H0 executable does not satisfy its exact identity requirement: {path}",
    )
    displayed = run_bounded(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(path)],
        timeout=timeout,
    )
    require(displayed.returncode == 0 and not displayed.timed_out, "cannot inspect code signature")
    details = parse_codesign_details(
        (displayed.stdout + displayed.stderr).decode("utf-8", errors="replace")
    )
    require(details["identifier"] == expected_identifier, f"wrong identifier for {path}")
    require(details["team_identifier"] == expected_team, f"wrong team identifier for {path}")
    require(re.fullmatch(r"[0-9a-f]{40}", details["cdhash"]) is not None, "malformed CDHash")
    require("runtime" in details["code_directory"], f"hardened runtime is absent for {path}")
    require(
        any(
            authority.startswith(str(admission["authority_prefix"]))
            for authority in details["authorities"]
        ),
        f"unexpected signing certificate class for {path}",
    )

    designated = run_bounded(
        ["/usr/bin/codesign", "--display", "-r-", str(path)],
        timeout=timeout,
    )
    require(designated.returncode == 0 and not designated.timed_out, "cannot read designated requirement")
    designated_requirement = parse_designated_requirement(
        (designated.stdout + designated.stderr).decode("utf-8", errors="replace")
    )
    require(expected_identifier in designated_requirement, "designated requirement omits identifier")

    entitlement_result = run_bounded(
        ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(path)],
        timeout=timeout,
    )
    require(
        entitlement_result.returncode == 0 and not entitlement_result.timed_out,
        f"cannot inspect entitlements for {path}",
    )
    entitlements = parse_entitlements(
        entitlement_result.stdout,
        expected_identifier,
        expected_team,
    )

    daemon_admission = run_bounded(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            "--verbose=4",
            f"-R={admission['requirement']}",
            str(path),
        ],
        timeout=timeout,
    )
    require(not daemon_admission.timed_out, "daemon admission rejection check timed out")
    require(
        daemon_admission.returncode != 0,
        f"H0 identity is unexpectedly admitted by the daemon requirement: {path}",
    )
    after = snapshot_regular_file(
        path,
        label="signed H0 executable",
        maximum_bytes=MAXIMUM_EXECUTABLE_BYTES,
        executable=True,
    )
    require_unchanged(before, after, "signed H0 executable")
    filesystem_after = qualified_signing_filesystem(path)
    require(
        filesystem_before == filesystem_after,
        f"signing filesystem changed during H0 inspection: {path}",
    )
    return {
        "path": str(path),
        "sha256": before.sha256,
        "filesystem": filesystem_before,
        "identifier": details["identifier"],
        "team_identifier": details["team_identifier"],
        "code_directory_hash": details["cdhash"],
        "hardened_runtime": True,
        "authorities": details["authorities"],
        "designated_requirement": designated_requirement,
        "entitlements": entitlements,
        "exact_identity_requirement_satisfied": True,
        "daemon_client_requirement_rejected": True,
    }


def canonical_json_line(value: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    ).encode("utf-8")


def validate_tool_output(
    raw: bytes,
    *,
    command: str,
    role: str,
    expected_path: pathlib.Path,
    expected_identifier: str,
    expected_team: str,
    expected_entitlements: Mapping[str, Any],
    expected_cdhash: str,
    expected_requirement_sha256: str,
    expected_pid: int,
    expected_parent_pid: int,
) -> dict[str, Any]:
    require(0 < len(raw) <= MAXIMUM_TOOL_JSON_BYTES, "H0 tool output is empty or oversized")
    value = strict_json_object(raw, label="H0 tool output")
    require(set(value) == READINESS_KEYS, "H0 tool output has missing or unexpected fields")
    require(canonical_json_line(value) == raw, "H0 tool output is not canonical one-line JSON")
    require(type(value["schema_version"]) is int and value["schema_version"] == 1, "wrong schema")
    require(value["command"] == command, "H0 tool reported the wrong command")
    require(value["role"] == role, "H0 tool reported the wrong role")
    require(
        type(value["process_id"]) is int and value["process_id"] == expected_pid,
        "H0 tool process ID does not match the launched process",
    )
    require(
        type(value["parent_process_id"]) is int
        and value["parent_process_id"] == expected_parent_pid,
        "H0 tool parent process ID does not match the runner",
    )
    require(
        type(value["effective_user_id"]) is int and value["effective_user_id"] == os.geteuid() > 0,
        "H0 tool effective user is invalid",
    )
    executable_path = value["executable_path"]
    require(
        isinstance(executable_path, str) and pathlib.Path(executable_path).is_absolute(),
        "H0 tool executable path is not absolute",
    )
    try:
        reported_path = pathlib.Path(executable_path).resolve(strict=True)
    except OSError as error:
        raise H0Error("H0 tool executable path is unavailable") from error
    require(reported_path == expected_path.resolve(strict=True), "H0 tool executable path changed")
    require(value["bundle_identifier"] == expected_identifier, "H0 tool identifier changed")
    require(value["signing_team_identifier"] == expected_team, "H0 tool signing team changed")
    require(
        value["signing_entitlements"] == dict(expected_entitlements),
        "H0 tool live entitlements differ from static inspection",
    )
    require(value["code_directory_hash"] == expected_cdhash, "H0 tool CDHash changed")
    require(value["hardened_runtime"] is True, "H0 tool lacks live hardened runtime")
    require(
        value["self_identity_requirement_satisfied"] is True,
        "H0 tool failed its live exact identity requirement",
    )
    require(
        value["daemon_client_requirement_sha256"] == expected_requirement_sha256,
        "H0 tool did not evaluate the exact compiled daemon client requirement",
    )
    require(
        value["daemon_client_requirement_satisfied"] is False,
        "H0 tool satisfies the compiled daemon client requirement",
    )
    require(
        value["team_only_admission_probe_satisfied"] is True,
        "H0 tool did not detect a broad team-only admission rule",
    )
    require(
        type(value["recorder_context_present"]) is bool,
        "H0 tool recorder-context flag is not Boolean",
    )
    if command == "self-check":
        require(value["recorder_context_present"] is True, "self-check lacks recorder context")
    require(value["supported_commands"] == EXPECTED_COMMANDS, "H0 command inventory changed")
    require(value["production_mutation_exercised"] is False, "H0 tool claimed production mutation")
    require(value["qualification_status"] == "not_run", "H0 tool advanced qualification")
    require(type(value["rows_updated"]) is int and value["rows_updated"] == 0, "rows advanced")
    require(
        type(value["formal_predicates_updated"]) is int
        and value["formal_predicates_updated"] == 0,
        "formal predicates advanced",
    )
    claims = value["completion_claims"]
    require(isinstance(claims, dict) and set(claims) == COMPLETION_CLAIM_KEYS, "claims changed")
    require(all(claims[key] is False for key in COMPLETION_CLAIM_KEYS), "completion was claimed")
    return value


def run_tool_command(
    path: pathlib.Path,
    *,
    role: str,
    command: str,
    signature: Mapping[str, Any],
    template_sha256: str,
    run_id: str,
    timeout: float,
) -> dict[str, Any]:
    require(command in EXPECTED_COMMANDS, "unsupported H0 command")
    before = snapshot_regular_file(
        path,
        label=f"{role} executable before launch",
        maximum_bytes=MAXIMUM_EXECUTABLE_BYTES,
        executable=True,
    )
    require(
        before.sha256 == signature["sha256"],
        f"{role} executable changed after signature inspection",
    )
    environment: dict[str, str] = {START_SUSPENDED_ENVIRONMENT_KEY: "1"}
    if command == "self-check":
        context = {
            "schema_version": 1,
            "run_id": run_id,
            "command": command,
            "role": role,
            "template_sha256": template_sha256,
        }
        encoded_context = json.dumps(context, sort_keys=True, separators=(",", ":"))
        require(
            len(encoded_context.encode("utf-8")) <= MAXIMUM_RECORDER_CONTEXT_BYTES,
            "recorder context exceeds its byte bound",
        )
        environment[RECORDER_CONTEXT_ENVIRONMENT_KEY] = encoded_context
    live_identity: dict[str, Any] = {}

    def bind_live_identity(process: subprocess.Popen[bytes]) -> None:
        stop_signal = wait_for_suspended_child(process, timeout)
        cdhash = live_process_cdhash(process.pid)
        require(
            cdhash == signature["code_directory_hash"],
            f"{role} live process CDHash differs from the inspected executable",
        )
        live_identity.update({
            "process_id": process.pid,
            "stop_signal": int(stop_signal),
            "code_directory_hash": cdhash,
            "matches_inspected_executable": True,
        })
        _signal_process_group(process.pid, signal.SIGCONT)

    result = run_bounded(
        [str(path), command],
        timeout=timeout,
        maximum_output_bytes=MAXIMUM_TOOL_JSON_BYTES,
        environment=environment,
        on_started=bind_live_identity,
    )
    require(not result.timed_out, f"{role} {command} timed out")
    require(
        result.returncode == 0,
        f"{role} {command} exited {result.returncode}: {bounded_text(result.stderr)}",
    )
    require(result.stderr == b"", f"{role} {command} emitted diagnostics")
    parsed = validate_tool_output(
        result.stdout,
        command=command,
        role=role,
        expected_path=path,
        expected_identifier=EXPECTED_IDENTIFIERS[role],
        expected_team=str(signature["team_identifier"]),
        expected_entitlements=dict(signature["entitlements"]),
        expected_cdhash=str(signature["code_directory_hash"]),
        expected_requirement_sha256=str(signature["daemon_requirement_sha256"]),
        expected_pid=result.pid,
        expected_parent_pid=os.getpid(),
    )
    after = snapshot_regular_file(
        path,
        label=f"{role} executable after launch",
        maximum_bytes=MAXIMUM_EXECUTABLE_BYTES,
        executable=True,
    )
    require_unchanged(before, after, f"{role} executable launch binding")
    return {
        "command": command,
        "role": role,
        "return_code": result.returncode,
        "timed_out": result.timed_out,
        "stdout_sha256": sha256_bytes(result.stdout),
        "stderr_bytes": len(result.stderr),
        "process_group_cleanup": result.process_group_cleanup,
        "live_process_identity": live_identity,
        "executable_snapshot_sha256": before.sha256,
        "result": parsed,
    }


def execute_controls(
    executables: Mapping[str, pathlib.Path],
    signatures: Mapping[str, Mapping[str, Any]],
    *,
    daemon_requirement_sha256: str,
    template_sha256: str,
    run_id: str,
    timeout: float,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for role in ("harness", "adversary"):
        signature = dict(signatures[role])
        signature["daemon_requirement_sha256"] = daemon_requirement_sha256
        for command in EXPECTED_COMMANDS:
            results.append(
                run_tool_command(
                    executables[role],
                    role=role,
                    command=command,
                    signature=signature,
                    template_sha256=template_sha256,
                    run_id=run_id,
                    timeout=timeout,
                )
            )
    return results


def repository_identity(timeout: float) -> dict[str, Any]:
    branch = run_bounded(
        ["/usr/bin/git", "-C", str(REPOSITORY_ROOT), "branch", "--show-current"],
        timeout=timeout,
        maximum_output_bytes=4096,
    )
    head = run_bounded(
        ["/usr/bin/git", "-C", str(REPOSITORY_ROOT), "rev-parse", "HEAD"],
        timeout=timeout,
        maximum_output_bytes=4096,
    )
    base = run_bounded(
        [
            "/usr/bin/git",
            "-C",
            str(REPOSITORY_ROOT),
            "rev-parse",
            "--verify",
            "refs/remotes/origin/main^{commit}",
        ],
        timeout=timeout,
        maximum_output_bytes=4096,
    )
    require(branch.returncode == 0 and not branch.timed_out, "cannot resolve active branch")
    require(head.returncode == 0 and not head.timed_out, "cannot resolve repository HEAD")
    require(base.returncode == 0 and not base.timed_out, "cannot resolve origin/main")
    branch_value = branch.stdout.decode("ascii", errors="strict").strip()
    head_value = head.stdout.decode("ascii", errors="strict").strip()
    base_value = base.stdout.decode("ascii", errors="strict").strip()
    require(branch_value and len(branch_value.encode("utf-8")) <= 256, "active branch is invalid")
    require(re.fullmatch(r"[0-9a-f]{40}", head_value) is not None, "repository HEAD is invalid")
    require(re.fullmatch(r"[0-9a-f]{40}", base_value) is not None, "origin/main is invalid")
    ancestry = run_bounded(
        [
            "/usr/bin/git",
            "-C",
            str(REPOSITORY_ROOT),
            "merge-base",
            "--is-ancestor",
            base_value,
            head_value,
        ],
        timeout=timeout,
        maximum_output_bytes=4096,
    )
    require(
        ancestry.returncode == 0 and not ancestry.timed_out,
        "origin/main is not an ancestor of execution HEAD",
    )
    return {
        "path": str(REPOSITORY_ROOT),
        "branch": branch_value,
        "head": head_value,
        "base_branch": "main",
        "base_sha": base_value,
    }


def false_completion_claims() -> dict[str, bool]:
    return {key: False for key in sorted(COMPLETION_CLAIM_KEYS)}


def initial_report(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "kind": "p10-privileged-filesystem-h0-readiness",
        "generated_at": utc_now(),
        "run_id": str(uuid.uuid4()),
        "mode": "execute" if args.execute else "preflight_only",
        "overall_status": "blocked",
        "production_mutation_exercised": False,
        "qualification_status": "not_run",
        "rows_updated": 0,
        "formal_predicates_updated": 0,
        "matrix": {"required_rows": None, "executed_rows": 0},
        "formal_closure": {"required_predicates": None, "proven_predicates": 0},
        "context_bound": False,
        "recorder_context_bound": False,
        "recorder_evidence_context": None,
        "smappservice_invoked": False,
        "smappservice_registered": False,
        "completion_claims": false_completion_claims(),
        "commands": [],
        "blocking_reasons": [],
        "release_blockers": [
            "E2 remains open: no signed-host matrix row was executed and the documented residual races remain.",
            "P10, G10, and G12 remain open pending the full product and filesystem qualification.",
            "Native Developer Mode UI, signing, and lifecycle qualification remains deferred and release-blocking.",
            "Real-provider autonomous continuity, GUI-closed operation, and crash recovery remain unproven.",
            "Real-hardware qualification remains deferred to the product owner and release-blocking.",
            "Executable path-replacement detection is an inode/ctime mitigation qualified only on local APFS; it does not eliminate same-UID interference.",
        ],
    }


def _resolved_for_comparison(path: pathlib.Path) -> pathlib.Path:
    return path.expanduser().resolve(strict=False)


def validate_output_path(
    output: pathlib.Path,
    *,
    protected_paths: list[pathlib.Path],
) -> pathlib.Path:
    require(output.is_absolute(), "--output must be an absolute path")
    resolved = _resolved_for_comparison(output)
    all_protected = protected_paths + [
        QUALIFICATION_TEMPLATE,
        CANONICAL_QUALIFICATION_REPORT,
        READINESS_SCHEMA,
    ]
    for protected in all_protected:
        protected_resolved = _resolved_for_comparison(protected)
        require(resolved != protected_resolved, f"output would overwrite protected input: {protected}")
        if output.exists() and protected.exists():
            try:
                require(
                    not os.path.samefile(output, protected),
                    f"output aliases protected input: {protected}",
                )
            except OSError as error:
                raise H0Error(f"cannot compare output with protected input: {error}") from error
    if os.path.lexists(output):
        metadata = output.lstat()
        require(not stat.S_ISLNK(metadata.st_mode), "output must not be a symlink")
        require(stat.S_ISREG(metadata.st_mode), "existing output must be a regular file")
        require(metadata.st_uid == os.geteuid(), "existing output must be owned by the current user")
    return resolved


def validate_ready_report_bindings(report: Mapping[str, Any]) -> None:
    if report["overall_status"] != "ready":
        return
    template = dict(report["canonical_qualification_template"])
    require(template["byte_stable"] is True, "ready report has no byte-stable template")
    require(
        template["before_sha256"] == template["after_sha256"],
        "ready report template digests differ",
    )
    repository = dict(report["repository"])
    signatures = dict(report["signatures"])
    require(set(signatures) == set(EXPECTED_IDENTIFIERS), "ready report signature roles differ")
    signature_paths: set[str] = set()
    signature_hashes: set[str] = set()
    signature_cdhashes: set[str] = set()
    for role, expected_identifier in EXPECTED_IDENTIFIERS.items():
        signature = dict(signatures[role])
        require(signature["identifier"] == expected_identifier, f"{role} signature identifier differs")
        require(
            signature["filesystem"]["identity_replacement_detection"]
            == "inode_and_ctime_on_local_apfs",
            f"{role} signature lacks the qualified replacement-detection precondition",
        )
        signature_paths.add(str(signature["path"]))
        signature_hashes.add(str(signature["sha256"]))
        signature_cdhashes.add(str(signature["code_directory_hash"]))
    require(len(signature_paths) == 2, "ready report signature paths are not distinct")
    require(len(signature_hashes) == 2, "ready report signature byte hashes are not distinct")
    require(len(signature_cdhashes) == 2, "ready report CodeDirectory hashes are not distinct")

    commands = list(report["commands"])
    if report["mode"] == "preflight_only":
        require(commands == [], "preflight-ready report unexpectedly contains command results")
        require(
            report["recorder_context_bound"] is False
            and report["recorder_evidence_context"] is None,
            "preflight-ready report unexpectedly claims recorder binding",
        )
        require(
            "describe and self-check remain unexecuted without explicit --execute"
            in report["blocking_reasons"],
            "preflight-ready report omits its unexecuted-control limitation",
        )
        return

    require(report["mode"] == "execute", "ready report has an unsupported mode")
    require(report["blocking_reasons"] == [], "execute-ready report contains blocking reasons")
    require(report["recorder_context_bound"] is True, "execute-ready report is not recorder-bound")
    recorder = dict(report["recorder_evidence_context"])
    recorder_repository = dict(recorder["repository"])
    require(
        recorder_repository
        == {
            "branch": repository["branch"],
            "head_sha": repository["head"],
            "base_branch": repository["base_branch"],
            "base_sha": repository["base_sha"],
            "repository_path": repository["path"],
        },
        "execute-ready report repository and recorder bindings differ",
    )
    expected_inventory = [
        (role, command)
        for role in ("harness", "adversary")
        for command in EXPECTED_COMMANDS
    ]
    require(len(commands) == len(expected_inventory), "execute-ready command count differs")
    daemon_requirement_sha256 = report["daemon_client_admission"]["requirement_sha256"]
    parent_process_ids: set[int] = set()
    for command_result, (role, command) in zip(commands, expected_inventory):
        require(
            (command_result["role"], command_result["command"]) == (role, command),
            "execute-ready command inventory or order differs",
        )
        signature = signatures[role]
        tool_result = command_result["result"]
        live_identity = command_result["live_process_identity"]
        require(
            (tool_result["role"], tool_result["command"]) == (role, command),
            f"{role} {command} inner result identity differs",
        )
        require(
            command_result["stdout_sha256"] == sha256_bytes(canonical_json_line(tool_result)),
            f"{role} {command} stdout digest differs from its durable result",
        )
        require(
            command_result["executable_snapshot_sha256"] == signature["sha256"],
            f"{role} {command} executable snapshot differs from signature inspection",
        )
        require(
            _resolved_for_comparison(pathlib.Path(tool_result["executable_path"]))
            == _resolved_for_comparison(pathlib.Path(signature["path"])),
            f"{role} {command} executable path differs from signature inspection",
        )
        require(
            tool_result["bundle_identifier"] == signature["identifier"]
            and tool_result["signing_team_identifier"] == signature["team_identifier"]
            and tool_result["signing_entitlements"] == signature["entitlements"]
            and tool_result["hardened_runtime"] == signature["hardened_runtime"],
            f"{role} {command} live signing facts differ from static inspection",
        )
        require(
            tool_result["code_directory_hash"] == signature["code_directory_hash"]
            and live_identity["code_directory_hash"] == signature["code_directory_hash"]
            and live_identity["process_id"] == tool_result["process_id"],
            f"{role} {command} live process identity differs from static inspection",
        )
        require(
            tool_result["daemon_client_requirement_sha256"] == daemon_requirement_sha256,
            f"{role} {command} daemon requirement binding differs",
        )
        require(
            tool_result["recorder_context_present"] is (command == "self-check"),
            f"{role} {command} recorder-context presence differs",
        )
        parent_process_ids.add(int(tool_result["parent_process_id"]))
    require(len(parent_process_ids) == 1, "execute-ready commands have different parent processes")


def validate_readiness_report_schema(report: Mapping[str, Any]) -> None:
    try:
        from jsonschema import Draft202012Validator
        from jsonschema.exceptions import SchemaError

        _, raw_schema = read_bounded_regular_bytes(
            READINESS_SCHEMA,
            label="H0 readiness schema",
            maximum_bytes=MAXIMUM_TEMPLATE_BYTES,
        )
        schema = strict_json_object(raw_schema, label="H0 readiness schema")
        Draft202012Validator.check_schema(schema)
        errors = sorted(
            Draft202012Validator(schema).iter_errors(dict(report)),
            key=lambda error: tuple(str(part) for part in error.absolute_path),
        )
    except ImportError as error:
        raise H0Error("H0 readiness schema runtime is unavailable") from error
    except (OSError, UnicodeError, ValueError, SchemaError) as error:
        raise H0Error(f"H0 readiness schema cannot be enforced: {error}") from error
    if errors:
        first = errors[0]
        location = ".".join(str(part) for part in first.absolute_path) or "<root>"
        raise H0Error(f"H0 readiness schema error at {location}: {first.message}")
    validate_ready_report_bindings(report)


def emit_report(report: Mapping[str, Any], output: pathlib.Path | None) -> None:
    validate_readiness_report_schema(report)
    encoded = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode("utf-8")
    require(len(encoded) <= MAXIMUM_REPORT_BYTES, "H0 readiness report exceeds its byte bound")
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        parent = output.parent.resolve(strict=True)
        target = parent / output.name
        descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=parent)
        temporary_path = pathlib.Path(temporary)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_path, target)
            parent_descriptor = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(parent_descriptor)
            finally:
                os.close(parent_descriptor)
        finally:
            if temporary_path.exists():
                temporary_path.unlink()
    sys.stdout.buffer.write(encoded)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate H0 identities and, only with --execute, run bounded describe and "
            "self-check controls. This runner never performs qualification mutations."
        )
    )
    parser.add_argument("--harness", required=True, type=pathlib.Path)
    parser.add_argument("--adversary", required=True, type=pathlib.Path)
    parser.add_argument("--expected-team", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--command-timeout", type=float, default=10.0)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    report = initial_report(args)
    output: pathlib.Path | None = None
    template_before: FileSnapshot | None = None
    exit_code = 2
    try:
        require(
            0 < args.command_timeout <= MAXIMUM_COMMAND_TIMEOUT_SECONDS,
            "--command-timeout is outside bounds",
        )
        require(re.fullmatch(r"[A-Z0-9]{10}", args.expected_team) is not None, "invalid team")
        require(PROTOCOL_SOURCE.is_absolute(), "protocol source path must be absolute")
        require(QUALIFICATION_TEMPLATE.is_absolute(), "qualification template path must be absolute")
        executables = validate_executable_paths(args.harness, args.adversary)
        output = validate_output_path(
            args.output,
            protected_paths=[
                executables["harness"],
                executables["adversary"],
                PROTOCOL_SOURCE,
                QUALIFICATION_TEMPLATE,
            ],
        )
        report["repository"] = repository_identity(args.command_timeout)
        recorder_context = validate_recorder_evidence_context(
            os.environ,
            required=args.execute,
            repository=report["repository"],
        )
        report["recorder_evidence_context"] = recorder_context
        report["recorder_context_bound"] = recorder_context is not None
        report["operator"] = validate_logged_in_user()
        template_before, template_contract = validate_nonpassing_qualification_template(
            QUALIFICATION_TEMPLATE
        )
        report["canonical_qualification_template"] = {
            "path": template_before.path,
            "before_sha256": template_before.sha256,
            "after_sha256": None,
            "byte_stable": False,
            "nonpassing_contract": template_contract,
        }
        report["matrix"] = {
            "required_rows": template_contract["matrix_rows_required"],
            "executed_rows": template_contract["matrix_rows_executed"],
        }
        report["formal_closure"] = {
            "required_predicates": template_contract["formal_predicates_required"],
            "proven_predicates": template_contract["formal_predicates_proven"],
        }
        admission = read_daemon_client_requirement(PROTOCOL_SOURCE, args.expected_team)
        report["daemon_client_admission"] = admission
        signatures: dict[str, dict[str, Any]] = {}
        for role in ("harness", "adversary"):
            signatures[role] = inspect_signature(
                executables[role],
                expected_identifier=EXPECTED_IDENTIFIERS[role],
                expected_team=args.expected_team,
                admission=admission,
                timeout=args.command_timeout,
            )
        require(
            signatures["harness"]["code_directory_hash"]
            != signatures["adversary"]["code_directory_hash"],
            "H0 executables unexpectedly share one CodeDirectory hash",
        )
        report["signatures"] = signatures
        report["overall_status"] = "ready"
        if args.execute:
            report["commands"] = execute_controls(
                executables,
                signatures,
                daemon_requirement_sha256=admission["requirement_sha256"],
                template_sha256=template_before.sha256,
                run_id=report["run_id"],
                timeout=args.command_timeout,
            )
            exit_code = 0
        else:
            report["blocking_reasons"].append(
                "describe and self-check remain unexecuted without explicit --execute"
            )
            exit_code = 3
    except (H0Error, OSError, UnicodeError) as error:
        report["overall_status"] = "blocked"
        report["blocking_reasons"].append(str(error))
        exit_code = 2
    finally:
        if template_before is not None:
            try:
                template_after = snapshot_regular_file(
                    pathlib.Path(template_before.path),
                    label="canonical qualification template",
                    maximum_bytes=MAXIMUM_TEMPLATE_BYTES,
                )
                require_unchanged(
                    template_before,
                    template_after,
                    "canonical qualification template",
                )
                report["canonical_qualification_template"]["after_sha256"] = (
                    template_after.sha256
                )
                report["canonical_qualification_template"]["byte_stable"] = True
            except (H0Error, OSError) as error:
                report["overall_status"] = "blocked"
                report["blocking_reasons"].append(str(error))
                exit_code = 2
        report["blocking_reasons"] = list(dict.fromkeys(report["blocking_reasons"]))
        try:
            emit_report(report, output)
        except (H0Error, OSError) as error:
            sys.stderr.write(f"cannot emit H0 readiness report: {error}\n")
            return 2
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
