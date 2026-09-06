#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  scripts/release.sh <version> [change summary]

Example:
  scripts/release.sh 1.5.2 "Publish rotated-image viewport fixes."

The script bumps VERSION, runs isolated tests, builds and verifies the ARM64
DMG locally, commits the release, creates an annotated tag, pushes main and the
tag, waits for the GitHub release workflow, then verifies the release and
Homebrew cask.
USAGE
}

version="${1:-}"
summary="${2:-}"

if [[ -z "$version" || "$version" == "-h" || "$version" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release version must be semantic, for example 1.5.2." >&2
    exit 1
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

for tool in git gh plutil codesign shasum file awk base64 ruby lipo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then
    echo "Release must be run from the main branch." >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree must be clean before releasing." >&2
    git status --short
    exit 1
fi

git fetch --tags origin

if git rev-parse "v$version" >/dev/null 2>&1; then
    echo "Tag v$version already exists locally." >&2
    exit 1
fi

if git ls-remote --exit-code --tags origin "v$version" >/dev/null 2>&1; then
    echo "Tag v$version already exists on origin." >&2
    exit 1
fi

previous_version="$(tr -d '[:space:]' < VERSION)"
if [[ "$previous_version" == "$version" ]]; then
    echo "VERSION is already $version; nothing to release." >&2
    exit 1
fi

printf '%s\n' "$version" > VERSION

cleanup_version() {
    if [[ -n "${release_committed:-}" ]]; then
        return
    fi
    printf '%s\n' "$previous_version" > VERSION
}
trap cleanup_version EXIT

echo "Running isolated regression tests..."
bash scripts/test.sh

build_number="${BUILD_NUMBER:-$(printf '%s' "$version" | tr -d '.')}"
echo "Building ARM64 DMG with BUILD_NUMBER=$build_number..."
SWIFT_BUILD_FLAGS="${SWIFT_BUILD_FLAGS:---arch arm64}" \
BUILD_NUMBER="$build_number" \
    scripts/create-dmg.sh

app_path=".build/Photonic.app"
dmg_path="dist/Photonic-$version.dmg"
checksum_path="$dmg_path.sha256"
binary_path="$app_path/Contents/MacOS/Photonic"

bundle_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
if [[ "$bundle_version" != "$version" ]]; then
    echo "Bundle version $bundle_version does not match $version." >&2
    exit 1
fi

if [[ ! -f "$dmg_path" || ! -f "$checksum_path" ]]; then
    echo "Expected DMG or checksum is missing from dist/." >&2
    exit 1
fi

if [[ "$(lipo -archs "$binary_path")" != "arm64" ]]; then
    file "$binary_path" >&2
    echo "Release binary is not ARM64-only." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
(cd dist && shasum -a 256 -c "Photonic-$version.dmg.sha256")

if [[ -z "$summary" ]]; then
    recent_changes="$(git log --format='- %s' "origin/main..HEAD")"
    if [[ -z "$recent_changes" ]]; then
        summary="Publish Photonic $version."
    else
        summary=$'Publish the following changes as Photonic '"$version"$':\n'"$recent_changes"
    fi
fi

git add VERSION
git commit -m "Release Photonic $version" -m "$summary"
release_committed=1
trap - EXIT

git tag -a "v$version" -m "Photonic $version"
git push origin main
git push origin "v$version"

echo "Waiting for GitHub release workflow..."
run_id=""
for _ in {1..20}; do
    run_id="$(gh run list \
        --repo wenLiangcan/Photonic \
        --workflow release.yml \
        --limit 10 \
        --json databaseId,headBranch,headSha,status \
        --jq ".[] | select(.headBranch == \"v$version\" and .headSha == \"$(git rev-parse HEAD)\") | .databaseId" \
        | head -n 1)"
    if [[ -n "$run_id" ]]; then
        break
    fi
    sleep 3
done

if [[ -z "$run_id" ]]; then
    echo "Could not find the GitHub Actions run for v$version." >&2
    exit 1
fi

gh run watch "$run_id" --repo wenLiangcan/Photonic --exit-status

release_json="$(gh release view "v$version" --repo wenLiangcan/Photonic --json url,assets)"
release_url="$(printf '%s' "$release_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("url")')"
release_checksum="$(printf '%s' "$release_json" | VERSION="$version" ruby -rjson -e 'name = "Photonic-#{ENV.fetch("VERSION")}.dmg"; asset = JSON.parse(STDIN.read).fetch("assets").find { |item| item["name"] == name }; abort "DMG asset not found" unless asset; puts asset.fetch("digest").sub(/^sha256:/, "")')"

tap_content="$(gh api repos/wenLiangcan/homebrew-photonic/contents/Casks/photonic.rb --jq .content | base64 --decode)"
tap_version="$(printf '%s' "$tap_content" | awk -F'"' '/^  version / { print $2 }')"
tap_checksum="$(printf '%s' "$tap_content" | awk -F'"' '/^  sha256 / { print $2 }')"

if [[ "$tap_version" != "$version" ]]; then
    echo "Homebrew tap version is $tap_version, expected $version." >&2
    exit 1
fi

if [[ "$tap_checksum" != "$release_checksum" ]]; then
    echo "Homebrew tap checksum does not match the release asset." >&2
    exit 1
fi

echo "Released Photonic $version"
echo "Release: $release_url"
echo "Checksum: $release_checksum"
