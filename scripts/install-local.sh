#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$repo_root/TmuxRooms.xcodeproj"
scheme="TmuxRooms"
build_dir="$repo_root/DerivedData"
destination="/Applications/Tmux Rooms.app"
app_path=""
approve_replace=0
dry_run=0
non_interactive=0
launch_after_install=1

usage() {
  cat <<'EOF'
Usage: scripts/install-local.sh [options]

Build, verify, and install the signed Release application.

Options:
  --yes                  explicitly approve replacing an existing destination
  --dry-run              build and verify, but do not copy or launch
  --non-interactive      never prompt; fail if replacement lacks --yes
  --no-launch            do not launch after installation
  --build-dir PATH       DerivedData directory (default: repo/DerivedData)
  --app-path PATH        verify/install an existing app instead of building
  --destination PATH     install destination (default: /Applications/Tmux Rooms.app)
  --help                 show this help
EOF
}

while (($#)); do
  case "$1" in
    --yes) approve_replace=1 ;;
    --dry-run) dry_run=1 ;;
    --non-interactive) non_interactive=1 ;;
    --no-launch) launch_after_install=0 ;;
    --build-dir) shift; build_dir="${1:?--build-dir requires a path}" ;;
    --app-path) shift; app_path="${1:?--app-path requires a path}" ;;
    --destination) shift; destination="${1:?--destination requires a path}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

if [[ -z "$app_path" ]]; then
  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -derivedDataPath "$build_dir" \
    build
  app_path="$build_dir/Build/Products/Release/Tmux Rooms.app"
fi

helper="$app_path/Contents/Helpers/tmuxrooms-launch"
[[ -d "$app_path" ]] || { echo "App bundle missing: $app_path" >&2; exit 1; }
[[ -x "$helper" ]] || { echo "Bundled helper missing or not executable: $helper" >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
codesign --verify --strict "$helper"

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/tmux-rooms-entitlements.XXXXXX")"
codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null
entitlements_json="$(plutil -convert json -o - "$entitlements_file" 2>/dev/null || true)"
rm -f "$entitlements_file"
if ! grep -Eq '"com\.apple\.security\.automation\.apple-events"[[:space:]]*:[[:space:]]*true' <<<"$entitlements_json"; then
  echo "App Apple Events entitlement is not enabled" >&2
  exit 1
fi

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
grep -q 'Authority=Tmux Rooms Local Development' <<<"$signature_details" || {
  echo "Unexpected signing identity" >&2
  exit 1
}
grep -Eq 'flags=.*runtime' <<<"$signature_details" || {
  echo "Hardened Runtime signature flag is missing" >&2
  exit 1
}

if [[ -e "$destination" && "$approve_replace" -ne 1 ]]; then
  if [[ "$non_interactive" -eq 1 || ! -t 0 ]]; then
    echo "Refusing to replace existing installation without --yes: $destination" >&2
    exit 2
  fi
  printf 'Existing installation found at %s. Type "replace" to continue: ' "$destination" >&2
  read -r answer
  [[ "$answer" == "replace" ]] || { echo "Replacement cancelled." >&2; exit 2; }
fi

if [[ "$dry_run" -eq 1 ]]; then
  echo "Dry run verified: $app_path"
  if [[ -e "$destination" ]]; then
    echo "Dry run would replace: $destination"
  else
    echo "Dry run would install: $destination"
  fi
  exit 0
fi

destination_parent="$(dirname "$destination")"
mkdir -p "$destination_parent"
staging="$destination_parent/.Tmux Rooms.app.installing.$$"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app_path" "$staging"
if [[ -e "$destination" ]]; then
  rm -rf "$destination"
fi
mv "$staging" "$destination"
trap - EXIT
codesign --verify --deep --strict "$destination"

if [[ "$launch_after_install" -eq 1 ]]; then
  open "$destination"
fi
echo "Installed: $destination"
