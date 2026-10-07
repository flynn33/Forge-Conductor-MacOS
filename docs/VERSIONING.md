# Versioning policy

**Preceding UI implementation and QA complete.** The
0.17.0 (27) source manifest 28548a73… passed **116 distinct production tests in 140
successful executions**, with zero failures/skips. The separate native view
matrix passed **21 unique methods in 22 invocations**; all **463 selected PNGs**
were individually opened and reviewed. The 15-check/434-input audit, matching
signed Debug build and four scoped ordinary workflows passed. Historical
failures and superseded inputs remain separate. Native caches, genuine Metal
readbacks and ordinary observations retain their explicit limits; no
installation, notarization, App Store upload or distribution was performed.
Exact owner publication/readback/synchronization refs are retained externally.

Current identity is **0.25.0 (35)**. The native PDF text/layout correction and shared
complete tagged-text reader advance the feature-release component. Tool names,
schemas, defaults and durable formats remain; generated PDF bytes/layout and
new converter provenance can change. The corrected owning-area source selection
passed 101 methods and the compiled native selection passed 102 tests on 450
unchanged inputs. The current marker regression and strict Debug/Release
signing/build binding passed; Qwen's separate two-document API exchange passed.
Independent r6 semantic validation passed 82 controls and all eight Debug, eight
Release and two Qwen artifacts with original scalar markers and 80 expectations
preserved. Its operand quota revision is external to the product. Native PNG
review covered ten Release and two Qwen PNG pages. The PDFKit whole mixed-script
order and Qwen wrapped-sentinel gates, a test capture warning and publication remain
open in
[native PDF writing](NATIVE-PDF-WRITING.md).

The preceding identity is **0.24.0 (34)**. Additive `fs_list`
continuation advances the feature-release component; current authority documents
advance with it. Its final 173 source and matching compiled Core cases, current
CLI/app builds, signed Debug/Release matrices and scoped Qwen continuation
passed. Interim failures and open installed/notice-bearing gates remain in
[filesystem list paging](FILESYSTEM-LIST-PAGING.md).
The preceding **0.23.0 (33)** native JavaScript snapshot receipts retain their
published identity in [native web rendering](NATIVE-WEB-RENDERING.md), including
an immutable source link. The later renderer LF correction has separate source
proof and later 0.24.0 LF-aware native qualification in the listing record;
original 0.23.0 JSON-only receipts keep their measurement scope.
The preceding 0.22.0 binary-web receipts remain in
[their record](BINARY-WEB-AND-QWEN-FILES.md). The preceding
**0.21.0 (31)** optional-tool inventory retains its tested identity in
[the inventory record](RUNTIME-INVENTORY.md). The preceding **0.20.0 (30)** expiry,
running-output and page-metadata receipts remain in [their follow-up](QWEN-FOLLOWUP.md). The published **0.19.0 (29)** project
GitHub and web/file receipts stay in [their feature record](PROJECT-WEB-QWEN.md).
The preceding **0.18.0 (28)** Xcode CLI
and continuity-setting receipts remain in [the repair record](LMSTUDIO-RUNTIME-REPAIR.md).

Preceding identity was **0.17.0 (27)**. The Graphite/Compute UI implementation and
native QA/check-refresh passed; exact owner publication/readback/synchronization refs are retained externally; version alignment and a signed build
are not shipment qualification. Historical receipts keep their tested identity.

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

## Current identity

The current product version is `0.25.0`, build `35`. `VERSION`, `BUILD_NUMBER`,
compiled protocol constants, all twelve Xcode marketing-version settings,
all sixteen build-number settings and current document markers must agree.
The current-version source/document regression passed one method and the compiled
native selection passed 102 tests, including that same marker check. Strict
Debug/Release verification bound seven/five candidate identities to successful
450-input builds. This documentation refresh still requires final review/publication;
Independent r6 semantic artifact validation and Release/Qwen render review passed
within their recorded scopes; original PDFKit compatibility failures and the test
capture warning remain open.
The corrected PDF owning-area
source selection passed 101 methods, while earlier build/source receipts retain
their exact pre-final inputs.
Historical product, filesystem protocol, plugin and database schema identities
are not globally replaced by this feature version.

### Preceding 0.24.0 version agreement

That checkpoint's product version is `0.24.0`, build `34`. Backward-compatible directory
continuation advances the feature-release component and resets the patch
component. `VERSION`, `BUILD_NUMBER`, protocol constants, all 12 Xcode
marketing-version settings, all 16 build-number settings and the current
authority-document markers agree. The current-version regression passed in
the final source selection and matching compiled native selection. An earlier
corrected Swift CLI build passed before the raw-token and pre-normalization
boundary corrections. Current corrected-input CLI/app and signed Debug/Release
builds passed separately. The preceding 0.23.0
actual version regression passed in source and in its compiled selection with
every assertion retained; its renderer, 0.22.0 binary-web and 0.21.0 inventory
receipts keep their own tested scopes.

The preceding 0.17.0 exact-reference source audit passed 15/15 checks over 434 inputs.
That preceding 0.17.0 434-input ordinary Debug build passed strict signing/
compiled-library/exact reference packaging and four scoped manual ordinary
workflows. Its native QA and final checks passed; exact owner publication/
readback/synchronization refs are retained externally. The prior 433-input
artifact retains its checkpoint identity.
[Compute Cores](COMPUTE-CORES.md#current-material-source-audit) records exact
corrected audit/candidate/checkpoint hashes. The fifth material pilot,
116-distinct production coverage, native view/control QA and source check
refresh belong to that preceding checkpoint; exact owner publication refs are
retained externally in [Graphite Workbench](GRAPHITE-WORKBENCH.md).
Exact source/wiki publication refs are recorded externally without
self-referential commits. Prior passes retain their tested inputs.

Installed apps and historical evidence retain their actual identities.
The October 3 `0.16.5 (26)` archive/export evidence is not relabeled as a
`0.17.0 (27)` qualification; see [qualification status](QUALIFICATION-STATUS.md).

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

The preceding 0.17.0 checkpoint's initial G1 document-version case failed one
assertion for the missing exact XCODE marker. The marker is restored, the test remains unchanged
and its focused rerun passed one actual case, zero failures/skips, terminal 0
(0.010s; command 1.980s). The failed log is preserved in Compute checkpoint
history; no test or product identity changed.
