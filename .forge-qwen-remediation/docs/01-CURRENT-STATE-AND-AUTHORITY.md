# Current state and authority

## Supplied source identity

- Repository archive: `inputs/Forge-Conductor-MacOS-main.zip`
- Archive SHA-256: `8b38cd6bf86f0e90a4fa0567fcc8e7e7ead88285f64e03880efe894d19c6aeb7`
- Generated stable source manifest: `evidence/current-source-manifest.json`

The archive has no trustworthy `.git` history. Do not infer branch ancestry from embedded state files. When bootstrapping from the archive, the archive checksum and source manifest are authoritative.

## Audit authority

`audit/Findings.tsv` contains thirty findings. `plans/finding-to-work-package.json` maps every finding to remediation work. `audit/Feature-Coverage-Matrix.tsv` records which of the twelve original capability packages are implemented, partial, or missing.

## Specialist design authority

- `inputs/Forge-Conductor-Autonomous-Continuity-Implementation-Design.zip`
- `inputs/Forge-Conductor-E2-Secure-Filesystem-Qwen Code-Package.zip`

The installer expands these to `.forge-continuity-design` and `.forge-e2`. Their source snapshots are historical reference only. Never replace the current repository with the snapshots inside those packages.

## Conflict resolution

Use the newest current repository source as implementation truth. Use this remediation package for priorities and gates. Use specialist packages for detailed continuity and E2 algorithms. When a specialist design conflicts with current source that already correctly implements a feature, preserve the current behavior and satisfy the newer invariant with the narrowest change.
