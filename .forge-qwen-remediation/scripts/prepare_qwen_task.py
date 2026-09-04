#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime as dt
import json
import subprocess
from pathlib import Path
from typing import Any

def load(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text())
    except Exception:
        return default

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    design = repo / ".forge-qwen-remediation"
    state_dir = repo / ".forge-qwen-state"
    state_dir.mkdir(exist_ok=True)

    state = load(state_dir / "run-state.json", {})
    handoff = load(state_dir / "current-handoff.json", {})
    profile = load(state_dir / "qwen-provider.json", {})
    selection = load(state_dir / "selected-work.json")

    if not selection or (
        selection.get("work_package") is None
        and selection.get("selected") is None
    ):
        selected = subprocess.run(
            [
                "python3",
                str(design / "scripts/select_next_work.py"),
                "--repo",
                str(repo),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        selection = (
            json.loads(selected.stdout)
            if selected.stdout.strip()
            else {"selected": None}
        )
    work_package = selection.get("work_package") or selection.get("selected")
    if not work_package:
        raise SystemExit("no ready work package")

    current = state.get("current_work_package")
    if current != work_package["id"]:
        selected_state = subprocess.run(
            [
                "python3",
                str(design / "scripts/statectl.py"),
                "--repo",
                str(repo),
                "select",
                work_package["id"],
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if selected_state.returncode != 0:
            raise SystemExit(
                "failed to select work package in durable state: "
                + (selected_state.stdout + selected_state.stderr)[-2000:]
            )
        state = load(state_dir / "run-state.json", state)

    card = (
        design
        / "qwen/work-package-cards"
        / f"{work_package['id']}.md"
    )
    digest = subprocess.check_output(
        [
            "python3",
            str(design / "scripts/source_manifest.py"),
            "--repo",
            str(repo),
            "--digest-only",
        ],
        text=True,
    ).strip()

    task = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "work_package": work_package,
        "source_manifest_sha256": digest,
        "handoff": handoff,
        "provider": profile,
        "gate_status": {
            gate: state.get("gate_status", {}).get(gate)
            for gate in work_package.get("gates", [])
        },
        "card_path": (
            card.relative_to(repo).as_posix()
            if card.exists()
            else None
        ),
    }
    (state_dir / "selected-work.json").write_text(
        json.dumps(task, indent=2) + "\n"
    )

    lines = [
        f"# Current Qwen remediation task — {work_package['id']}",
        "",
        f"**Title:** {work_package['title']}",
        f"**Objective:** {work_package['objective']}",
        f"**Source manifest:** `{digest}`",
        f"**Model:** `{profile.get('model_id', 'not configured')}`",
        f"**Card:** `{task['card_path']}`",
        "",
        "## Read first",
    ]
    for item in [
        task["card_path"],
        ".forge-qwen-state/current-handoff.json",
        ".forge-qwen-remediation/AGENTS.md",
    ]:
        if item:
            lines.append(f"- `{item}`")
    lines += ["", "## Candidate source targets"]
    lines += [
        f"- `{target}`"
        for target in work_package.get("source_targets", [])
    ]
    lines += ["", "## Required focused tests"]
    lines += [
        f"- {test}"
        for test in work_package.get("required_tests", [])
    ]
    lines += [
        "",
        "## Current handoff",
        handoff.get("summary", "No prior summary."),
        "",
        f"**Next:** {handoff.get('next_action', 'Establish the smallest evidence-backed next step.')}",
        "",
        "## Mandatory stop rules",
        "- Complete only one coherent slice.",
        "- Do not pass gates from narrative output.",
        "- Preserve shell access and every current feature.",
        "- Update the durable handoff before exit.",
        "- Do not ship, publish, push, tag, merge, notarize, or distribute.",
    ]
    (state_dir / "current-task.md").write_text(
        "\n".join(lines) + "\n"
    )
    print(json.dumps(task, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
