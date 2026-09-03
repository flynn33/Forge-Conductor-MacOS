# E2 integration

The installed `.forge-e2` package is the detailed algorithmic authority.

## Closure requirement

Do not perform:

```text
fstatat(path) -> compare -> unlinkat(path)
```

or equivalent verify-then-destruct pathname sequences for protected operations.

Use descriptor-bound roots and atomic namespace capture/publication as the linearization point. Inspect the captured object, then commit, restore, or quarantine. Cross-volume operations copy from pinned descriptors into private destination-volume staging, verify, synchronize, publish exclusively, then dispose of the captured source transaction.

## Package ingestion dependency

Package extraction and immutable store publication use the same broker. Do not implement ingestion using Foundation archive extraction followed by post-hoc path checks.

## Platform capability

Probe supported public Darwin flags and filesystem volume capabilities at runtime. Unsupported operations fail closed with a typed result. Never silently fall back to the known race.

## Completion

E2 closes only after the adversarial attacker matrix and formal closure argument pass. Quarantine-and-verify without atomic capture remains mitigation, not closure.
