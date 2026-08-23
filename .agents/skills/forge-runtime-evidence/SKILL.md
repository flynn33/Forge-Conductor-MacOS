---
name: forge-runtime-evidence
description: Collect and interpret macOS build, leak, Instruments, sanitizer, OSLog, SwiftUI, and Metal evidence for Forge Conductor.
---

# Forge Runtime Evidence

## Build

Use the narrowest affected target first, then the entire app. Keep one project-local `script/build_and_run.sh`. Classify compiler, linker, signing, assertion, crash, hang, race, resource, migration, protocol, environment, or flake failures.

## Memory

Exercise a precise create/use/release flow. Capture at the release boundary. Find the first app-owned retained type and ownership path. Re-run the identical flow after the patch. Lower aggregate memory alone does not prove release.

## Performance

Use Release configuration and signposts. Compare identical machine, fixture, warm-up, duration, and actions. Record distributions for CPU, wakeups, allocations, resident-size trajectory, SwiftUI invalidations, Metal cadence/resource creation, database latency, and queue depth.

## Logging

Use unified logging with stable categories and privacy annotations. Do not use raw project/model content. Verify events through filtered log collection.

## Gate evidence

Capture commands through `record_command.py`, preserve raw artifacts with hashes, and use criterion-specific acceptance records. Never write a paper-only pass.
