# Release readiness attestation

## Attestation binds

- source archive and clean source manifest;
- Git tree/commit when a real Git checkout exists;
- toolchain versions, SDK, architecture, deployment target;
- package/Xcode target inventory;
- test and validator receipts;
- signed app/helper hashes and entitlements;
- release-candidate archive hash;
- database schema/migration versions;
- SBOM/dependency inventory;
- open finding count by severity;
- `ready_to_ship` and `shipped` booleans.

## Evidence coherence

All mandatory gate receipts must reference the same accepted source manifest or an explicitly recorded successor manifest produced during the release-candidate build. A receipt from another branch, source tree, project generation, or validator version is not accepted.

## Final values

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```

The attestation must not claim Developer ID distribution or notarization unless actually performed. Local test signing is identified as local qualification only.
