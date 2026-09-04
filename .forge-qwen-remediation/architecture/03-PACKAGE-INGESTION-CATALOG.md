# Instruction-package ingestion and catalog

## Inputs

- directory selected through Finder;
- ZIP archive;
- `.forgepackage` archive;
- existing `.forge-codex` layout through compatibility import.

## Pipeline

```text
discovered
  -> staging
  -> structuralValidation
  -> contentValidation
  -> immutableCommit
  -> cataloged
```

Failure branches are `invalid`, `quarantined`, or `retryWaiting`. The manager never executes directly from the source path.

## Validation limits

- archive compressed and uncompressed byte caps;
- file-count cap;
- path-component and total-path limits;
- reject absolute paths, `..`, NUL, control characters, duplicate normalized paths, case collisions on case-insensitive volumes, and unsupported file types;
- reject symlinks/hard links by default; a future manifest version may permit internal links only after an explicit secure policy;
- reject device nodes, sockets, FIFOs, and extended attributes outside an allowlist;
- verify every extracted file through descriptor-bound E2-safe operations;
- hash canonical manifest and content tree;
- copy to a private same-volume staging tree, synchronize, and publish atomically into `Store/<sha256>`.

## Manifest

The schema in `schemas/forge-package.schema.json` requires stable package ID, version, mission, project binding requirements, dependency IDs, requested capabilities, completion gates, resource policy, entry documents, and artifact declarations.

## Immutability

Cataloged content is read-only by policy and addressed by digest. Runs receive a content digest and an isolated writable workspace. A package source may disappear or change after ingestion without affecting the catalog.

## Quarantine

Quarantine records retain source descriptor, reason code, bounded diagnostic metadata, and cleanup policy. Quarantined content receives no model, runtime, or tool authority.
