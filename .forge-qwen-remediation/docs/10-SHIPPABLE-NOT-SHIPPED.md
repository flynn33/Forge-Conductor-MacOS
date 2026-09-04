# Shippable, not shipped

## Ready-to-ship criteria

- all mandatory gates in `plans/gates.json` pass;
- no Critical or High finding remains open;
- Medium findings are fixed or explicitly accepted with no contradiction to the requested feature contract;
- source, toolchain, test, profile, and artifact identities are bound in one attestation;
- migration and rollback notes are complete;
- a local release candidate launches under Gatekeeper/local signing conditions;
- `ready_to_ship=true` and `shipped=false`.

## Stop condition

After producing the release candidate and attestation, stop. Do not merge, tag, publish, upload, notarize for distribution, submit, or update an external release channel. If a private notarization test is deemed necessary, it requires an already configured credential and an explicit local-only evidence policy; it may not make the artifact publicly available.
