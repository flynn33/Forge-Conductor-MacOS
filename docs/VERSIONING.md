# Versioning policy

Forge Conductor uses a three-part product version:

```text
<release>.<feature release>.<patch or hotfix>
```

The format is numeric and has no omitted components. For example, `0.10.0`
means release line `0`, feature release `10`, patch `0`.

## When each component changes

| Change | Component | Example |
| --- | --- | --- |
| Incompatible product or persistence contract | Release | `1.4.2` → `2.0.0` |
| Backward-compatible user-facing feature | Feature release | `1.4.2` → `1.5.0` |
| Backward-compatible correction or hotfix | Patch or hotfix | `1.4.2` → `1.4.3` |

Increasing a component resets every component to its right to zero. A product
version may advance before shipment; release status is recorded separately in
the changelog and qualification documents.

## Canonical files

- `VERSION` contains the product version and is the repository authority.
- `BUILD_NUMBER` contains the monotonically increasing bundle build number.
- `ForgeFilesystemProtocolConstants` exposes the same values to every native
  product.
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` expose the values to Xcode
  and every shipped bundle.

Update all four surfaces together. `script/check_repository_hygiene.sh`, the
focused version test, and CI reject drift between them.

## Release checklist

1. Choose the next version from the rules above.
2. Increment `BUILD_NUMBER` for every distributed candidate.
3. Update `VERSION`, the compiled constants, and all Xcode configurations.
4. Add the user-visible changes to `CHANGELOG.md`.
5. Update the current version references in the README and active guides.
6. Run the repository hygiene check, focused version test, builds, and relevant
   feature tests.
7. Tag only the exact qualified commit selected for release.

Historical evidence keeps the version it actually tested. Do not rewrite an old
receipt merely because the current product version advanced.
