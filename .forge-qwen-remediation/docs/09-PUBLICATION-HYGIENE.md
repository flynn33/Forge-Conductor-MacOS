# Publication hygiene

## Human identity

Use only the repository owner’s configured human author and committer identity. Preserve existing author configuration. Do not add co-author trailers or generator credit.

## Prohibited publication text

Do not add phrases that credit automated tooling, model names, assistants, generators, or code-generation services in commits, branches, pull requests, source headers, comments, documentation, screenshots, artifacts, release notes, or metadata.

Functional product documentation may describe models, providers, MCP, and autonomous operation. That is product behavior, not authorship credit.

## Scan

Run `scripts/scan_publication_hygiene.py` before every checkpoint and final attestation. Review any match rather than blindly deleting legitimate functional terminology.
