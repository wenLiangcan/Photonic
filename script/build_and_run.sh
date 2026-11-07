#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
    run|--verify|--debug|--logs|--telemetry) ;;
    *) echo "Usage: $0 [run|--verify|--debug|--logs|--telemetry] [image paths...]" >&2; exit 2 ;;
esac

# Reuse the app's canonical packaging path, including its Icon Composer asset.
# Only stop an instance launched from this checkout.
app_bundle="$project_dir/.build/Photonic.app"
app_binary="$app_bundle/Contents/MacOS/Photonic"
while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid"
done < <(pgrep -f "^${app_binary}$" || true)
SWIFT_BUILD_FLAGS='--arch arm64' "$project_dir/scripts/package-app.sh" debug

if [[ "$mode" == --debug ]]; then
    exec lldb -- "$app_binary" "$@"
fi
/usr/bin/open -n "$app_bundle" --args "$@"
case "$mode" in
    --verify)
        sleep 1
        pgrep -f "$app_binary" >/dev/null
        ;;
    --logs|--telemetry)
        exec /usr/bin/log stream --info --style compact --predicate 'process == "Photonic"'
        ;;
esac
