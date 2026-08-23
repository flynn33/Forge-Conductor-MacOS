# Project Memory Model

## Record semantics

A memory record is a durable project-scoped unit of information. It is not synonymous with a chat message.

Required properties:

- stable UUID;
- project UUID;
- version;
- kind;
- compact title and summary;
- optional detailed body;
- provenance;
- importance and confidence;
- timestamps;
- content hash;
- schema version;
- deletion/tombstone state.

## Provenance

Provenance identifies how the record arose without storing secrets or an entire transcript:

- user requirement;
- repository source;
- test result;
- runtime trace;
- model decision;
- imported artifact;
- continuity checkpoint;
- external integration.

Store a bounded source reference such as file/symbol, test ID, evidence hash, or session ID.

## Decision memory

A decision record includes:

- problem;
- evidence;
- constraints;
- alternatives;
- selection;
- consequences;
- rollback;
- affected feature IDs.

Superseded decisions link to the replacement; they are not silently overwritten.

## Task and issue memory

Tasks have explicit state and dependencies. Issues retain evidence class/severity, reproducer, fix attempt, and gate relationships. The autonomous run ledger may reference memory IDs rather than duplicate content.

## Deduplication

Compute a normalized content hash scoped by project and kind. Exact duplicates return the prior record. Near-duplicate merging is never automatic unless an explicit deterministic policy can preserve provenance.

## Retention

Default retention:

- constraints, decisions, migrations, handoffs, and feature contracts: durable;
- transient test attempts and diagnostics: policy-bounded;
- generated search result caches: non-durable;
- raw model chunks: not project memory by default.

Compaction creates a new summary linked to source records; it does not erase protected records until retention policy allows.

## Retrieval

Return compact summaries first. The caller requests bodies by ID. Ranking must be deterministic enough for tests and include score components in diagnostics mode.

Search response budget applies to encoded bytes in addition to item count.

## Serialization

Use strict versioned JSON at MCP boundaries and typed Swift value models internally. Unknown additive fields are ignored or preserved according to compatibility policy; unknown required versions return a typed error.

## Privacy

Before persistence:

- strip provider credentials;
- redact recognized secrets;
- reject disallowed binary/oversized input;
- normalize paths to project-relative form where possible;
- mark sensitive records and restrict export.
