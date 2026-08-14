#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
project="$repo_root/TmuxRooms.xcodeproj"
scheme="TmuxRooms"
build_dir="$repo_root/DerivedData"
destination="/Applications/Tmux Rooms.app"
app_path=""
approve_replace=0
dry_run=0
non_interactive=0
launch_after_install=1
expected_identity="Tmux Rooms Local Development"

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

die_safety() { echo "Unsafe destination: $*" >&2; exit 3; }
die_verification() { echo "Bundle verification failed: $*" >&2; exit 4; }

normalize_source() {
  local path="$1" parent base
  [[ "$path" == /* ]] || die_verification "source app path must be absolute"
  [[ ! -L "$path" ]] || die_verification "source app path is a symlink"
  [[ -d "$path" ]] || die_verification "app bundle missing: $path"
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$base"
}

normalize_destination() {
  local path="$1" parent base normalized home_real
  [[ "$path" == /* ]] || die_safety "path must be absolute"
  [[ "$path" != "/" ]] || die_safety "root is never an install destination"
  [[ "$path" == *.app ]] || die_safety "path must have an .app suffix"
  base="$(basename "$path")"
  [[ "$base" == "Tmux Rooms.app" ]] || die_safety "bundle name must be exactly Tmux Rooms.app"
  [[ ! -L "$path" ]] || die_safety "path is a symlink or dangling symlink"
  parent="$(dirname "$path")"
  [[ -d "$parent" ]] || die_safety "destination parent must already exist"
  normalized="$(cd "$parent" && pwd -P)/$base"
  home_real="$(cd "$HOME" && pwd -P)"
  [[ "$normalized" != "$home_real" && "$normalized" != "$home_real/"* ]] || die_safety "destination cannot be HOME or inside HOME"
  [[ "$normalized" != "$repo_root" && "$normalized" != "$repo_root/"* ]] || die_safety "destination cannot be the repository or inside it"
  [[ "$repo_root" != "$normalized/"* ]] || die_safety "destination cannot be an ancestor of the repository"
  printf '%s\n' "$normalized"
}

entitlements_json() {
  local executable="$1" output
  output="$(mktemp "${TMPDIR:-/tmp}/tmux-rooms-entitlements.XXXXXX")"
  if ! codesign -d --entitlements :- "$executable" >"$output" 2>/dev/null; then
    rm -f "$output"
    return 1
  fi
  if [[ ! -s "$output" ]]; then
    rm -f "$output"
    printf '{}\n'
    return 0
  fi
  plutil -convert json -o - "$output" 2>/dev/null | tr -d '[:space:]'
  local rc=${PIPESTATUS[0]}
  rm -f "$output"
  return "$rc"
}

signature_details() {
  codesign -dv --verbose=4 "$1" 2>&1
}

certificate_requirement_hash() {
  codesign -d -r- "$1" 2>&1 |
    sed -nE 's/.*certificate (leaf|root) = H"([0-9a-fA-F]+)".*/\2/p' |
    head -n 1 |
    tr '[:upper:]' '[:lower:]'
}

validate_bundle() {
  local bundle="$1" helper details helper_details app_entitlements helper_entitlements app_hash helper_hash matches bundle_id
  helper="$bundle/Contents/Helpers/tmuxrooms-launch"
  [[ -d "$bundle" && ! -L "$bundle" ]] || { echo "not a regular app bundle: $bundle" >&2; return 1; }
  [[ -x "$helper" && ! -L "$helper" ]] || { echo "exact helper is missing or not executable: $helper" >&2; return 1; }
  matches="$(find "$bundle/Contents" -name tmuxrooms-launch -print)"
  [[ "$matches" == "$helper" ]] || { echo "helper must exist only at Contents/Helpers/tmuxrooms-launch" >&2; return 1; }
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "com.tellang.tmuxrooms" ]] || { echo "unexpected bundle identifier: $bundle_id" >&2; return 1; }
  codesign --verify --deep --strict "$bundle" || return 1
  codesign --verify --strict "$helper" || return 1

  details="$(signature_details "$bundle")"
  helper_details="$(signature_details "$helper")"
  grep -q "Authority=$expected_identity" <<<"$details" || { echo "app signing identity mismatch" >&2; return 1; }
  grep -q "Authority=$expected_identity" <<<"$helper_details" || { echo "helper signing identity mismatch or ad-hoc signature" >&2; return 1; }
  ! grep -q 'Signature=adhoc' <<<"$details" || { echo "app must not be ad-hoc signed" >&2; return 1; }
  ! grep -q 'Signature=adhoc' <<<"$helper_details" || { echo "helper must not be ad-hoc signed" >&2; return 1; }
  grep -Eq 'flags=.*runtime' <<<"$details" || { echo "app Hardened Runtime flag is missing" >&2; return 1; }
  grep -Eq 'flags=.*runtime' <<<"$helper_details" || { echo "helper Hardened Runtime flag is missing" >&2; return 1; }

  app_hash="$(certificate_requirement_hash "$bundle")"
  helper_hash="$(certificate_requirement_hash "$helper")"
  [[ -n "$app_hash" && "$app_hash" == "$helper_hash" ]] || { echo "app/helper designated requirements do not bind the same certificate" >&2; return 1; }

  app_entitlements="$(entitlements_json "$bundle")" || { echo "cannot read app entitlements" >&2; return 1; }
  [[ "$app_entitlements" == '{"com.apple.security.automation.apple-events":true}' ]] || {
    echo "app entitlement allowlist mismatch: $app_entitlements" >&2
    return 1
  }
  helper_entitlements="$(entitlements_json "$helper")" || { echo "cannot read helper entitlements" >&2; return 1; }
  [[ "$helper_entitlements" == '{}' ]] || { echo "helper must have no entitlements: $helper_entitlements" >&2; return 1; }
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
  if [[ "$build_dir" != /* ]]; then
    build_dir="$repo_root/$build_dir"
  fi
  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -derivedDataPath "$build_dir" \
    build
  app_path="$build_dir/Build/Products/Release/Tmux Rooms.app"
fi

app_path="$(normalize_source "$app_path")"
destination="$(normalize_destination "$destination")"
[[ "$destination" != "$app_path" && "$destination" != "$app_path/"* && "$app_path" != "$destination/"* ]] || {
  die_safety "source and destination must not be identical or nested"
}
validate_bundle "$app_path" || die_verification "source bundle rejected"

destination_exists=0
if [[ -e "$destination" ]]; then
  destination_exists=1
  validate_bundle "$destination" || die_safety "existing destination is not a verified Tmux Rooms bundle"
fi

# A dry run never needs destructive approval because it exits before mutation.
if [[ "$dry_run" -eq 1 ]]; then
  echo "Dry run verified: $app_path"
  if [[ "$destination_exists" -eq 1 ]]; then
    echo "Dry run would replace: $destination"
  else
    echo "Dry run would install: $destination"
  fi
  exit 0
fi

if [[ "$destination_exists" -eq 1 && "$approve_replace" -ne 1 ]]; then
  if [[ "$non_interactive" -eq 1 || ! -t 0 ]]; then
    echo "Refusing to replace existing installation without --yes: $destination" >&2
    exit 2
  fi
  printf 'Existing installation found at %s. Type "replace" to continue: ' "$destination" >&2
  read -r answer
  [[ "$answer" == "replace" ]] || { echo "Replacement cancelled." >&2; exit 2; }
fi

destination_parent="$(dirname "$destination")"
install_container="$(mktemp -d "$destination_parent/.tmux-rooms-install.XXXXXX")"
backup_container="$(mktemp -d "$destination_parent/.tmux-rooms-backup.XXXXXX")"
staging="$install_container/Tmux Rooms.app"
backup="$backup_container/Tmux Rooms.app"
backup_active=0
destination_swapped=0
transaction_complete=0

safe_cleanup_container() {
  local path="$1" prefix="$2"
  [[ -n "$path" && ! -L "$path" && -d "$path" ]] || return 0
  [[ "$(dirname "$path")" == "$destination_parent" && "$(basename "$path")" == "$prefix".* ]] || {
    echo "Refusing unsafe cleanup path: $path" >&2
    return 1
  }
  /bin/rm -rf -- "$path"
}

rollback_transaction() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "$transaction_complete" -ne 1 ]]; then
    if [[ "$destination_swapped" -eq 1 && -e "$destination" && ! -L "$destination" ]]; then
      mv "$destination" "$install_container/failed-Tmux Rooms.app" || true
    fi
    if [[ "$backup_active" -eq 1 && -e "$backup" && ! -L "$backup" ]]; then
      mv "$backup" "$destination" || true
      backup_active=0
    fi
  fi
  safe_cleanup_container "$install_container" '.tmux-rooms-install' || true
  safe_cleanup_container "$backup_container" '.tmux-rooms-backup' || true
  exit "$rc"
}
trap rollback_transaction EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto "$app_path" "$staging"
if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_PHASE:-}" == staging ]]; then
  echo "Injected staging verification failure" >&2
  exit 5
fi
validate_bundle "$staging" || exit 5

if [[ "$destination_exists" -eq 1 ]]; then
  mv "$destination" "$backup"
  backup_active=1
fi
mv "$staging" "$destination"
destination_swapped=1

if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_PHASE:-}" == final ]]; then
  echo "Injected final verification failure" >&2
  exit 5
fi
validate_bundle "$destination" || exit 5

safe_cleanup_container "$backup_container" '.tmux-rooms-backup'
backup_active=0
destination_swapped=0
transaction_complete=1
safe_cleanup_container "$install_container" '.tmux-rooms-install' || echo "Warning: verified install succeeded but staging cleanup failed" >&2
trap - EXIT INT TERM

if [[ "$launch_after_install" -eq 1 ]]; then
  open "$destination"
fi
echo "Installed: $destination"
