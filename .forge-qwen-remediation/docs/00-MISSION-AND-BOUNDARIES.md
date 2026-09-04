# Mission and boundaries

## Product result

Forge Conductor must be a reliable native macOS orchestration application with project-scoped memory MCP, manager-owned autonomous package execution, durable context continuity, real-provider rollover, shell and external runtimes, bounded telemetry and rendering, secure filesystem mutation, safe reset, and complete operator controls.

## Current-state premise

The repository is an advanced partial implementation. Preserve its working foundations. Do not rewrite the application or replace the manager, memory, continuity, runtime, telemetry, or Metal systems wholesale.

## Required missing capabilities

- gate-specific deterministic completion validators;
- immutable instruction-package ingestion and catalog;
- durable Work Queue, reservation leases, package tools, and UI;
- selective crash-safe project reset;
- signed hardened XPC runtime profile;
- complete provider, project, runtime, continuity, and queue controls;
- operational resource-pressure policy and retention;
- E2 atomic namespace transaction closure;
- signed native, real-provider, low-memory, and endurance qualification.

## Release definition

The code is shippable only when all mandatory gates pass against one source manifest and one local release candidate. No Critical or High source finding may remain open. Environment limitations must be resolved with automated local test infrastructure or recorded as a non-product distribution prerequisite; they cannot be used to mark a product gate passed.
