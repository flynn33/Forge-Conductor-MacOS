# Durable budget policy

The manager persists version 1 budget preferences inside the existing `config.json` as `budget_policy`. Global defaults and overrides for an exact project ID and generation share one configuration transaction. Existing shell opt-outs and unrelated settings are preserved. Product identity remains 0.9.0 build 1.

## Settings contract

The authenticated manager settings route accepts a `budget_update` as a separate transaction. The typed `ManagerSettingsPatch.budgetPolicyUpdate` and dashboard client use this route. A request includes its scope, expected scope revision, expected global revision, operation, and a complete policy for `set`.

- `set` saves a complete validated policy.
- `reset` restores built-in defaults globally, or inheritance for a project.
- `inherit` returns a project to the current global default.

A project reset retains a revision-bearing inheritance entry so an old editor cannot overwrite a later reset. An unedited project starts at revision 0; the initial global revision is 1. Project policy saves hold the control-plane database writer transaction through the configuration compare-and-swap, excluding a concurrent generation reset. The scope must still be active.

Conflicts return HTTP 409 with `code: budget_policy_conflict` and `current_policy`. The editor must reload before making another decision. Invalid requests return HTTP 400 with a field and reason, plus a permitted range where applicable. Raw numeric counts are checked before Foundation conversion, including decimal tails beyond its precision, integral exponent notation, duplicate/escaped keys, booleans, overflow, and bounded input size. Legacy integer strings remain supported only in their existing settings fields.

The configuration file is locked, updated durably and read back before success. Ordinary settings writes apply only requested fields to the latest file; they cannot restore an old shell-enabled snapshot or overwrite a newer policy. Malformed stored policy preserves its original bounded backup and exposes a configuration error with no executable policy. It does not silently install defaults over the invalid source.

## Requested and effective policy

A saved preference is requested policy. The existing managed runtime resolves it again at each controlled provider/tool boundary, including cached sessions and restart recovery. `budget_policy_requested` records the save; the durable run event `budget_policy_effective` records the effective scope/revisions, source, requested context, verified loaded capacity, effective context and boundary.

Auto uses the verified loaded context window. Manual uses the smaller of the requested context and that window. The advertised model maximum is kept separately, and a preference never loads a model or expands its context window. A provider reconnect or model change revalidates loaded identity and recalculates the effective value.

At one defined accounting cut, admission uses retained input plus future reserves against effective capacity. Retained schemas and delivered tool envelopes are counted once. A repeated preflight carries the same pending-input identity and does not add the same input again. The response boundary normalizes provider input and output counters while retaining the raw aggregate for diagnosis. Overflow without usable current counts stays unknown, with zero confidence and an emergency decision.

Checkpoint, rollover and emergency ratios apply to the same admitted total. Reserves include future response/tool capacity, handoff, recovery and safety, without adding the legacy adaptive reserve a second time. Existing legacy observations remain readable; new observation metadata and effective events commit with the existing budget state transaction and remain subject to its retention bounds.

## Defaults and remaining delivery work

New tool preferences start at 8 calls per turn, 64 per session, 512 per run, 2 in flight, 65,536 raw result bytes, 4,096 retained result tokens and 4 recovery calls per rollover. These are new policy defaults, not claims about the earlier runtime. Context preferences start in Auto; reserves are derived from actual loaded capacity when unspecified. Automatic handoff enrollment starts disabled and requires an authenticated operator change.

This policy and context-accounting layer does not complete the later tool-reservation, native budget Settings, automatic enrollment, or live continuity gates. Those phases must enforce run-wide call reservations, expose requested/effective controls in the native UI, and qualify actual provider and desktop behavior. Saving a policy alone is not proof that the full instruction package is complete.
