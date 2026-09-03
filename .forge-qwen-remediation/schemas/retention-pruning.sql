-- Blueprint only. Production code must run pruning through bounded, project-aware
-- transactions and protect all rows referenced by nonterminal operations and receipts.

-- Example selection for archival; do not execute as a monolithic delete.
SELECT event_id
FROM autonomy_events
WHERE project_id = :project_id
  AND created_at < :cutoff
  AND event_id NOT IN (SELECT event_id FROM protected_event_references)
ORDER BY created_at
LIMIT :batch_size;

-- After writing and verifying an immutable archive for the selected IDs:
DELETE FROM autonomy_events
WHERE event_id IN (SELECT id FROM prune_batch_ids);
