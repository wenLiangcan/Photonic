# Photonic Agent Notes

## Commit Discipline

- Always write commit messages that describe the actual change.
- Keep commits focused. Do not mix unrelated cleanup into feature, fix, or release commits.
- Preserve user changes already present in the working tree unless the user explicitly asks to revert them.

## Release Process

Use the release script for normal releases:

```bash
scripts/release.sh <version> "Describe the changes being published."
```

Example:

```bash
scripts/release.sh 1.5.2 "Publish rotated-image viewport fixes and release automation."
```

The script is the canonical release flow. It:

1. Validates the semantic version and checks for existing tags.
2. Requires a clean `main` working tree.
3. Bumps `VERSION`, which is the source of truth for the app version.
4. Runs the isolated regression tests with `scripts/test.sh`.
5. Builds an ARM64-only DMG through `scripts/create-dmg.sh`.
6. Verifies the app bundle version, ARM64 architecture, code signature, and DMG checksum.
7. Commits the version bump with `Release Photonic <version>` and the supplied change summary.
8. Creates annotated tag `v<version>`.
9. Pushes `main` and the release tag to GitHub.
10. Waits for the GitHub Actions release workflow.
11. Verifies the published GitHub release and the Homebrew cask version/checksum.

If the script fails before creating the release commit, it restores `VERSION` to the previous value. If it fails after pushing, inspect the GitHub Actions run and retry only the failed external step where appropriate.

## Packaging

- Future releases are ARM64-only.
- `VERSION` must contain the marketing version, for example `1.5.2`.
- `BUILD_NUMBER` may be supplied to the release or packaging scripts; otherwise the release script derives it by removing dots from the version.
- Full Xcode 26 or newer is required because packaging compiles `Resources/Photonic.icon` with Apple's `actool`.
- `Resources/Photonic.icon` is the only app icon source of truth. Do not add hand-generated icon fallbacks.

## Homebrew

- The release workflow updates the separate tap repository: `wenLiangcan/homebrew-photonic`.
- GitHub Actions must have the `HOMEBREW_TAP_TOKEN` secret with read/write Contents access to that tap repository.
- If only the tap update needs retrying, use the **Update Homebrew Cask** workflow with the already-published version.

## Verification Commands

For local checks without releasing:

```bash
bash scripts/test.sh
SWIFT_BUILD_FLAGS='--arch arm64' BUILD_NUMBER=1 scripts/create-dmg.sh
```

After packaging, verify:

```bash
plutil -extract CFBundleShortVersionString raw .build/Photonic.app/Contents/Info.plist
lipo -archs .build/Photonic.app/Contents/MacOS/Photonic
codesign --verify --deep --strict --verbose=2 .build/Photonic.app
(cd dist && shasum -a 256 -c Photonic-<version>.dmg.sha256)
```
