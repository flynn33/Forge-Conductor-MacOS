#!/usr/bin/env python3
"""Focused regressions for fail-closed checkpoint publication identity."""

from __future__ import annotations

import json
import pathlib
import unittest
from collections.abc import Sequence

from checkpoint_identity import resolve_checkpoint_identity


LOCAL_BRANCH = "repair/e2-qualification-next"
PUBLISHED_BRANCH = "security/e2-harness-controls"
HEAD_SHA = "a" * 40
BASE_SHA = "b" * 40


class FixtureRunner:
    def __init__(self, overrides: dict[tuple[str, ...], tuple[int | None, str]] | None = None):
        self.overrides = overrides or {}
        self.calls: list[tuple[str, ...]] = []

    def __call__(
        self,
        repository: pathlib.Path,
        arguments: Sequence[str],
        timeout_seconds: int,
    ) -> tuple[int | None, str]:
        del repository, timeout_seconds
        key = tuple(arguments)
        self.calls.append(key)
        defaults = {
            ("git", "branch", "--show-current"): (0, LOCAL_BRANCH),
            ("git", "rev-parse", "HEAD"): (0, HEAD_SHA),
            ("git", "rev-parse", "origin/main"): (0, BASE_SHA),
            ("git", "rev-parse", "refs/remotes/origin/main"): (0, BASE_SHA),
            (
                "git",
                "config",
                "--get-all",
                f"branch.{LOCAL_BRANCH}.remote",
            ): (0, "origin"),
            (
                "git",
                "config",
                "--get-all",
                f"branch.{LOCAL_BRANCH}.merge",
            ): (0, f"refs/heads/{PUBLISHED_BRANCH}"),
            (
                "git",
                "rev-parse",
                f"refs/remotes/origin/{PUBLISHED_BRANCH}",
            ): (0, HEAD_SHA),
            (
                "gh",
                "pr",
                "list",
                "--head",
                PUBLISHED_BRANCH,
                "--state",
                "open",
                "--limit",
                "2",
                "--json",
                "number,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,url",
            ): (
                0,
                json.dumps([
                    {
                        "number": 19,
                        "state": "OPEN",
                        "isDraft": True,
                        "baseRefName": "main",
                        "baseRefOid": BASE_SHA,
                        "headRefName": PUBLISHED_BRANCH,
                        "headRefOid": HEAD_SHA,
                        "url": "https://example.invalid/pull/19",
                    }
                ]),
            ),
        }
        return self.overrides.get(key, defaults.get(key, (1, "")))


class CheckpointIdentityTests(unittest.TestCase):
    def test_differently_named_configured_upstream_is_publication_branch(self) -> None:
        result = resolve_checkpoint_identity(pathlib.Path("/fixture"), runner=FixtureRunner())

        self.assertEqual(result["active_branch"], LOCAL_BRANCH)
        self.assertEqual(result["publication_remote"], "origin")
        self.assertEqual(result["publication_head_branch"], PUBLISHED_BRANCH)
        self.assertEqual(result["head_sha"], HEAD_SHA)
        self.assertEqual(result["remote_head_sha"], HEAD_SHA)
        self.assertEqual(result["pull_request"]["number"], 19)
        self.assertEqual(result["identity_resolution"], "verified")
        self.assertTrue(result["github_readback_verified"])

    def test_no_configured_upstream_does_not_guess_from_active_branch(self) -> None:
        runner = FixtureRunner({
            (
                "git",
                "config",
                "--get-all",
                f"branch.{LOCAL_BRANCH}.remote",
            ): (1, ""),
            (
                "git",
                "config",
                "--get-all",
                f"branch.{LOCAL_BRANCH}.merge",
            ): (1, ""),
        })

        result = resolve_checkpoint_identity(pathlib.Path("/fixture"), runner=runner)

        self.assertEqual(result["active_branch"], LOCAL_BRANCH)
        self.assertIsNone(result["publication_head_branch"])
        self.assertIsNone(result["pull_request"])
        self.assertEqual(result["identity_resolution"], "no_configured_upstream")
        self.assertFalse(result["github_readback_verified"])
        self.assertFalse(any(call[:3] == ("gh", "pr", "list") for call in runner.calls))

    def test_ambiguous_upstream_configuration_fails_closed(self) -> None:
        runner = FixtureRunner({
            (
                "git",
                "config",
                "--get-all",
                f"branch.{LOCAL_BRANCH}.merge",
            ): (
                0,
                f"refs/heads/{PUBLISHED_BRANCH}\nrefs/heads/other-publication",
            ),
        })

        result = resolve_checkpoint_identity(pathlib.Path("/fixture"), runner=runner)

        self.assertIsNone(result["publication_head_branch"])
        self.assertIsNone(result["pull_request"])
        self.assertEqual(
            result["identity_resolution"],
            "ambiguous_upstream_configuration",
        )
        self.assertFalse(result["github_readback_verified"])
        self.assertFalse(any(call[:3] == ("gh", "pr", "list") for call in runner.calls))

    def test_multiple_open_pull_requests_fail_closed_without_selection(self) -> None:
        gh_call = (
            "gh",
            "pr",
            "list",
            "--head",
            PUBLISHED_BRANCH,
            "--state",
            "open",
            "--limit",
            "2",
            "--json",
            "number,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,url",
        )
        pull_request = {
            "state": "OPEN",
            "isDraft": True,
            "baseRefName": "main",
            "baseRefOid": BASE_SHA,
            "headRefName": PUBLISHED_BRANCH,
            "headRefOid": HEAD_SHA,
            "url": "https://example.invalid/pull",
        }
        runner = FixtureRunner({
            gh_call: (0, json.dumps([
                {**pull_request, "number": 19},
                {**pull_request, "number": 20},
            ])),
        })

        result = resolve_checkpoint_identity(pathlib.Path("/fixture"), runner=runner)

        self.assertEqual(result["publication_head_branch"], PUBLISHED_BRANCH)
        self.assertIsNone(result["pull_request"])
        self.assertEqual(result["identity_resolution"], "ambiguous_open_pull_requests")
        self.assertFalse(result["github_readback_verified"])

    def test_pull_request_base_oid_must_match_local_remote_tracking_ref(self) -> None:
        gh_call = (
            "gh",
            "pr",
            "list",
            "--head",
            PUBLISHED_BRANCH,
            "--state",
            "open",
            "--limit",
            "2",
            "--json",
            "number,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,url",
        )
        runner = FixtureRunner({
            gh_call: (0, json.dumps([
                {
                    "number": 19,
                    "state": "OPEN",
                    "isDraft": True,
                    "baseRefName": "main",
                    "baseRefOid": "c" * 40,
                    "headRefName": PUBLISHED_BRANCH,
                    "headRefOid": HEAD_SHA,
                    "url": "https://example.invalid/pull/19",
                }
            ])),
        })

        result = resolve_checkpoint_identity(pathlib.Path("/fixture"), runner=runner)

        self.assertEqual(result["base_sha"], BASE_SHA)
        self.assertEqual(result["identity_resolution"], "pull_request_readback_mismatch")
        self.assertFalse(result["github_readback_verified"])


if __name__ == "__main__":
    unittest.main()
