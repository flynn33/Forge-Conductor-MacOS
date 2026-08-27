# FC-BUDGET-001 decision and change summary

Context enforcement is now a persisted manager responsibility. The supervisor selects the
exact configured loaded model instance, validates its active context length against the
model maximum, and stores the resolved capacity with the provider session. Provider or
model configuration changes force reevaluation before more work is issued.

Each observation records the strongest available evidence: provider-exact usage,
model-tokenizer usage, a conservative serialized estimate, or a provider overflow signal.
The persisted record includes capacity, used and reserved tokens, response identity,
confidence, estimator version, trigger, and the moving growth estimates needed to project
the next turn.

Thresholds are calculated from explicit output, tool-schema, handoff, and recovery reserves
for the active context size. Hysteresis prevents repeated checkpoint oscillation, and a
fresh successor remains disarmed until bounded bootstrap usage is observed. An overflow
becomes an immediate emergency rollover.

Checkpoint and rollover requests are durable, deduplicated control-plane actions. They are
created automatically before or after provider turns and tool growth; the model does not
need to call a continuity tool. Restart reconstructs the current budget state and pending
action, while checkpoint-to-rollover escalation reuses one operation rather than creating a
conflicting active rollover.
