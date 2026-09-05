# Shipping integrity and native CI

These standard-library Python and shell utilities are build/test automation.
They do not install a manager, request privileged execution, sign, notarize, or
authorize distribution. The existing completion verifier remains the product
readiness authority.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .forge-codex/shipping/tests -v
python3 .forge-codex/shipping/scripts/shipping_guard.py versions --repo "$PWD"
python3 .forge-codex/shipping/scripts/shipping_guard.py xcode --repo "$PWD"
```

The version guard can additionally inspect effective Xcode settings through
`--settings path.json` and a built application through `--app path.app`. Nested
artifact signatures, compiled peer identity, resources and runtime behavior need
the existing native bundle and runtime qualifiers.

The Xcode guard parses the native project and verifies tracked production Swift
source membership. Its test-source omissions require explicit disposition and
actual coverage; a membership pass does not establish complete native tests.

The documentation guard accepts `docs --repo "$PWD" --base BASE_SHA --review
REVIEW_JSON`, optionally with `--index` or `--release`. It checks review coverage,
actual diffs, and regular-file existence in the selected HEAD/index snapshot.
Untracked copies cannot conceal deleted documents. Review content accuracy
separately. `--release` requires updates to README, CHANGELOG, USER-GUIDE and
XCODE across the selected range. The `sync` command reads live fetch/push refs
for one clean checkout; run it separately for execution and canonical checkouts.

The native workflow runs source integrity, Debug/Release Swift tests with
warnings as errors, and Debug/Release unsigned Xcode app and CLI compilation.
Its uploaded logs, xUnit results, Xcode result bundles and settings are CI
evidence only. It uses fresh GitHub-hosted Macs, read-only repository permission,
no saved checkout credentials, no signing secrets and no privileged hosts.

To reproduce one lane locally, set `FORGE_CI_OUTPUT_DIR` to an absolute, unused
evidence directory and invoke `bash .forge-codex/shipping/scripts/native_ci.sh`
with `integrity`, `swift-debug`, `swift-release`, `xcode-debug` or `xcode-release`.
Retain a separate output directory per invocation. Run native lanes only on a
compatible Mac; these commands do not exercise the installed service or GUI.

Runner/toolchain availability was checked on 2026-09-04 against GitHub's
[runner labels](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)
and [macOS 26 arm64 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
The workflow uses `macos-26` and explicitly selects Xcode 26.6 (17F113), failing
if that toolchain or architecture is unavailable. Actions are pinned to the
verified commits for [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1)
and [upload-artifact v7.0.1](https://github.com/actions/upload-artifact/releases/tag/v7.0.1).
Runner images can change; the recorded toolchain check must continue to pass.
