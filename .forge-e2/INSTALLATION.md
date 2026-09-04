# Installation

The package installs as `.forge-e2` inside an existing Forge Conductor
checkout. It does not overwrite application source.

```bash
./scripts/install_into_repo.sh /absolute/path/to/Forge-Conductor-MacOS
```

The installer:

1. verifies the destination is a Git checkout;
2. records the destination HEAD;
3. stages the package in a temporary directory;
4. validates JSON, Python, shell syntax, hashes, and required files;
5. atomically replaces an older `.forge-e2` directory;
6. preserves the previous package as `.forge-e2.backup.<timestamp>`;
7. initializes `.forge-e2-state` without deleting prior state.

The uploaded source ZIP is included only as historical input evidence.
It must never replace a newer repository checkout.
