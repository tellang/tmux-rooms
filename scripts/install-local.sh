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
expected_fingerprint=""

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
  local path="$1" parent base normalized home_real home_path="$HOME"
  [[ "$path" == /* ]] || die_safety "path must be absolute"
  [[ "$path" != "/" ]] || die_safety "root is never an install destination"
  [[ "$path" == *.app ]] || die_safety "path must have an .app suffix"
  base="$(basename "$path")"
  [[ "$base" == "Tmux Rooms.app" ]] || die_safety "bundle name must be exactly Tmux Rooms.app"
  [[ ! -L "$path" ]] || die_safety "path is a symlink or dangling symlink"
  parent="$(dirname "$path")"
  [[ -d "$parent" ]] || die_safety "destination parent must already exist"
  normalized="$(cd "$parent" && pwd -P)/$base"
  if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && -n "${TMUX_ROOMS_TEST_HOME:-}" ]]; then
    home_path="$TMUX_ROOMS_TEST_HOME"
  fi
  home_real="$(cd "$home_path" && pwd -P)"
  [[ "$normalized" != "$home_real" ]] || die_safety "destination cannot be HOME"
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

resolve_expected_fingerprint() {
  local matches
  matches="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40}) "Tmux Rooms Local Development"$/\1/p')"
  [[ "$(grep -c . <<<"$matches")" -eq 1 ]] || return 1
  tr '[:lower:]' '[:upper:]' <<<"$matches"
}

embedded_leaf_fingerprint() {
  local executable="$1" cert_dir prefix fingerprint
  cert_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-rooms-cert.XXXXXX")"
  prefix="$cert_dir/cert-"
  if ! codesign -d --extract-certificates="$prefix" "$executable" >/dev/null 2>&1 || [[ ! -f "${prefix}0" ]]; then
    rm -rf "$cert_dir"
    return 1
  fi
  fingerprint="$(shasum -a 1 "${prefix}0" | awk '{print toupper($1)}')"
  rm -rf "$cert_dir"
  printf '%s\n' "$fingerprint"
}

certificate_requirement_hash() {
  codesign -d -r- "$1" 2>&1 |
    sed -nE 's/.*certificate (leaf|root) = H"([0-9a-fA-F]+)".*/\2/p' |
    head -n 1 |
    tr '[:upper:]' '[:lower:]'
}

validate_bundle() {
  local bundle="$1" helper details helper_details app_entitlements helper_entitlements app_hash helper_hash matches bundle_id app_fingerprint helper_fingerprint
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
  grep -Fxq "Authority=$expected_identity" <<<"$details" || { echo "app signing identity mismatch" >&2; return 1; }
  grep -Fxq "Authority=$expected_identity" <<<"$helper_details" || { echo "helper signing identity mismatch or ad-hoc signature" >&2; return 1; }
  ! grep -q 'Signature=adhoc' <<<"$details" || { echo "app must not be ad-hoc signed" >&2; return 1; }
  ! grep -q 'Signature=adhoc' <<<"$helper_details" || { echo "helper must not be ad-hoc signed" >&2; return 1; }
  grep -Eq 'flags=.*runtime' <<<"$details" || { echo "app Hardened Runtime flag is missing" >&2; return 1; }
  grep -Eq 'flags=.*runtime' <<<"$helper_details" || { echo "helper Hardened Runtime flag is missing" >&2; return 1; }

  app_hash="$(certificate_requirement_hash "$bundle")"
  helper_hash="$(certificate_requirement_hash "$helper")"
  [[ -n "$app_hash" && "$app_hash" == "$helper_hash" ]] || { echo "app/helper designated requirements do not bind the same certificate" >&2; return 1; }
  app_fingerprint="$(embedded_leaf_fingerprint "$bundle")" || { echo "cannot extract app leaf certificate" >&2; return 1; }
  helper_fingerprint="$(embedded_leaf_fingerprint "$helper")" || { echo "cannot extract helper leaf certificate" >&2; return 1; }
  [[ "$app_fingerprint" == "$expected_fingerprint" && "$helper_fingerprint" == "$expected_fingerprint" ]] || {
    echo "app/helper leaf certificate fingerprint does not match the unique Keychain identity" >&2
    return 1
  }

  app_entitlements="$(entitlements_json "$bundle")" || { echo "cannot read app entitlements" >&2; return 1; }
  [[ "$app_entitlements" == '{"com.apple.security.automation.apple-events":true}' ]] || {
    echo "app entitlement allowlist mismatch: $app_entitlements" >&2
    return 1
  }
  helper_entitlements="$(entitlements_json "$helper")" || { echo "cannot read helper entitlements" >&2; return 1; }
  [[ "$helper_entitlements" == '{}' ]] || { echo "helper must have no entitlements: $helper_entitlements" >&2; return 1; }
}

executable_hash() {
  local bundle="$1"
  [[ -x "$bundle/Contents/MacOS/TmuxRooms" ]] || return 1
  shasum -a 256 "$bundle/Contents/MacOS/TmuxRooms" | awk '{print $1}'
}

write_journal() {
  local transaction="$1" phase="$2" old_hash="$3" new_hash="$4" temp="$transaction/journal.new"
  umask 077
  if [[ ! -d "$transaction" ]]; then
    [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_PHASE:-}" != "$phase" || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_STEP:-}" != mkdir ]] || return 1
    mkdir -m 700 "$transaction" || return 1
  fi
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_PHASE:-}" != "$phase" || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_STEP:-}" != temp-write ]] || return 1
  printf 'phase=%s\nold_hash=%s\nnew_hash=%s\n' "$phase" "$old_hash" "$new_hash" >"$temp" || return 1
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_PHASE:-}" != "$phase" || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_STEP:-}" != temp-sync ]] || return 1
  /bin/sync || return 1
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_PHASE:-}" != "$phase" || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_STEP:-}" != rename ]] || return 1
  mv "$temp" "$transaction/journal" || return 1
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_PHASE:-}" != "$phase" || "${TMUX_ROOMS_TEST_FAIL_JOURNAL_STEP:-}" != final-sync ]] || return 1
  /bin/sync || return 1
}

record_journal_or_preserve() {
  local transaction="$1" phase="$2" old_hash="$3" new_hash="$4"
  if ! write_journal "$transaction" "$phase" "$old_hash" "$new_hash"; then
    preserve_transaction=1
    echo "Journal update failed at phase '$phase'; transaction preserved: $transaction" >&2
    return 1
  fi
}

journal_value() {
  local journal="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$journal"
}

safe_cleanup_transaction() {
  local transaction="$1" parent="$2"
  [[ -d "$transaction" && ! -L "$transaction" ]] || return 0
  [[ "$(dirname "$transaction")" == "$parent" && "$(basename "$transaction")" == .tmux-rooms-transaction.* ]] || return 1
  /bin/rm -rf -- "$transaction"
}

build_atomic_swap_tool() {
  local output_dir="$1" output clang sdk
  output="$output_dir/atomic-swap"
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_ATOMIC_BUILD:-}" != xcrun ]] || return 1
  clang="$(xcrun --find clang)" || return 1
  sdk="$(xcrun --sdk macosx --show-sdk-path)" || return 1
  [[ -x "$clang" ]] || return 1
  [[ -d "$sdk" ]] || return 1
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_ATOMIC_BUILD:-}" != clang ]] || return 1
  "$clang" -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -O2 "$repo_root/scripts/atomic-swap.c" -o "$output" || return 1
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_ATOMIC_BUILD:-}" != chmod ]] || return 1
  chmod 755 "$output" || return 1
  [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" != 1 || "${TMUX_ROOMS_TEST_FAIL_ATOMIC_BUILD:-}" != executable ]] || return 1
  [[ -x "$output" ]] || return 1
  printf '%s\n' "$output"
}

recover_pending_transaction() {
  local parent="$1" destination_path="$2"
  local -a transactions=()
  local transaction journal staged phase old_hash new_hash destination_hash staged_hash
  while IFS= read -r transaction; do transactions+=("$transaction"); done < <(find "$parent" -maxdepth 1 -type d -name '.tmux-rooms-transaction.*' -print | sort)
  [[ "${#transactions[@]}" -le 1 ]] || {
    echo "Ambiguous installer recovery; preserving transactions:" >&2
    printf '  %s\n' "${transactions[@]}" >&2
    exit 6
  }
  [[ "${#transactions[@]}" -eq 1 ]] || return 0
  transaction="${transactions[0]}"
  journal="$transaction/journal"
  staged="$transaction/Tmux Rooms.app"
  if [[ -e "$transaction/journal.new" || -L "$transaction/journal.new" ]]; then
    echo "Incomplete journal.new detected; transaction and original candidate preserved: $transaction" >&2
    echo "state_path=$transaction/journal.new original_candidate=$staged" >&2
    exit 6
  fi
  [[ -f "$journal" && ! -L "$journal" ]] || { echo "Ambiguous transaction preserved: $transaction" >&2; exit 6; }
  phase="$(journal_value "$journal" phase)"
  old_hash="$(journal_value "$journal" old_hash)"
  new_hash="$(journal_value "$journal" new_hash)"
  [[ -n "$phase" && -n "$old_hash" && -n "$new_hash" ]] || { echo "Invalid transaction journal preserved: $transaction" >&2; exit 6; }
  if [[ "$phase" == rollback-failed || "$phase" == rollback-attempt ]]; then
    echo "Rollback transaction requires manual recovery; preserved original candidate at: $staged" >&2
    exit 6
  fi
  destination_hash="$(executable_hash "$destination_path" 2>/dev/null || echo MISSING)"
  staged_hash="$(executable_hash "$staged" 2>/dev/null || echo MISSING)"
  case "$phase:$destination_hash:$staged_hash" in
    "prepared:$old_hash:$new_hash")
      echo "Recovering prepared transaction before swap: $transaction" >&2
      safe_cleanup_transaction "$transaction" "$parent" || { echo "Prepared transaction cleanup failed; preserved: $transaction" >&2; exit 6; }
      ;;
    "prepared:MISSING:$new_hash")
      [[ "$old_hash" == NONE ]] && validate_bundle "$staged" || {
        echo "First-install prepared transaction is inconsistent; preserved: $transaction" >&2
        exit 6
      }
      echo "Recovering first-install prepared transaction before rename: $transaction" >&2
      safe_cleanup_transaction "$transaction" "$parent" || { echo "First-install prepared cleanup failed; preserved: $transaction" >&2; exit 6; }
      ;;
    "prepared:$new_hash:$old_hash"|"swapped:$new_hash:$old_hash"|"committed:$new_hash:$old_hash")
      validate_bundle "$destination_path" && validate_bundle "$staged" || {
        echo "Swapped transaction validation is ambiguous; preserved: $transaction" >&2
        exit 6
      }
      echo "Finalizing recovered atomic swap: $transaction" >&2
      safe_cleanup_transaction "$transaction" "$parent" || { echo "Recovered transaction cleanup failed; preserved: $transaction" >&2; exit 6; }
      ;;
    "prepared:$new_hash:MISSING"|"swapped:$new_hash:MISSING"|"committed:$new_hash:MISSING")
      [[ "$old_hash" == NONE ]] && validate_bundle "$destination_path" || {
        echo "New-install transaction validation is ambiguous; preserved: $transaction" >&2
        exit 6
      }
      echo "Finalizing recovered new install: $transaction" >&2
      safe_cleanup_transaction "$transaction" "$parent" || { echo "Recovered new-install cleanup failed; preserved: $transaction" >&2; exit 6; }
      ;;
    "swapped:$old_hash:$new_hash")
      validate_bundle "$destination_path" || { echo "Rolled-back destination invalid; preserved: $transaction" >&2; exit 6; }
      echo "Finalizing recovered rollback: $transaction" >&2
      safe_cleanup_transaction "$transaction" "$parent" || { echo "Recovered rollback cleanup failed; preserved: $transaction" >&2; exit 6; }
      ;;
    *)
      echo "Ambiguous transaction state '$phase'; preserving: $transaction" >&2
      echo "destination_hash=$destination_hash staged_hash=$staged_hash old_hash=$old_hash new_hash=$new_hash" >&2
      exit 6
      ;;
  esac
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

expected_fingerprint="$(resolve_expected_fingerprint)" || die_verification "expected signing identity must exist exactly once in the current Keychain"
if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && -n "${TMUX_ROOMS_TEST_EXPECTED_FINGERPRINT:-}" ]]; then
  expected_fingerprint="$TMUX_ROOMS_TEST_EXPECTED_FINGERPRINT"
fi
app_path="$(normalize_source "$app_path")"
destination="$(normalize_destination "$destination")"
[[ "$destination" != "$app_path" && "$destination" != "$app_path/"* && "$app_path" != "$destination/"* ]] || {
  die_safety "source and destination must not be identical or nested"
}
validate_bundle "$app_path" || die_verification "source bundle rejected"

destination_parent="$(dirname "$destination")"
atomic_tool_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-rooms-atomic-tool.XXXXXX")"
atomic_tool="$(build_atomic_swap_tool "$atomic_tool_dir")" || { rm -rf "$atomic_tool_dir"; die_verification "cannot build fixed atomic swap helper"; }
trap 'rm -rf "$atomic_tool_dir"' EXIT
recover_pending_transaction "$destination_parent" "$destination"

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

transaction="$(mktemp -d "$destination_parent/.tmux-rooms-transaction.XXXXXX")"
staging="$transaction/Tmux Rooms.app"
old_hash=NONE
new_hash=""
swap_completed=0
new_install_renamed=0
transaction_complete=0
preserve_transaction=0

rollback_transaction() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "$transaction_complete" -eq 1 ]]; then
    rm -rf "$atomic_tool_dir"
    exit "$rc"
  fi
  if [[ "$preserve_transaction" -eq 1 ]]; then
    echo "Installer transaction preserved for recovery: $transaction" >&2
    rm -rf "$atomic_tool_dir"
    exit "$rc"
  fi
  if [[ "$swap_completed" -eq 1 ]]; then
    if ! write_journal "$transaction" rollback-attempt "$old_hash" "$new_hash"; then
      echo "Cannot record rollback attempt; original app preserved at: $staging" >&2
      echo "Transaction preserved at: $transaction" >&2
      rm -rf "$atomic_tool_dir"
      exit 6
    fi
    if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_ROLLBACK_SWAP:-0}" == 1 ]] || ! "$atomic_tool" "$destination" "$staging"; then
      if ! write_journal "$transaction" rollback-failed "$old_hash" "$new_hash"; then
        echo "Rollback-failed journal update also failed; journal.new and transaction preserved" >&2
      fi
      echo "ROLLBACK FAILED; original app preserved at: $staging" >&2
      echo "Transaction preserved at: $transaction" >&2
      rm -rf "$atomic_tool_dir"
      exit 6
    fi
    swap_completed=0
    if [[ "$(executable_hash "$destination" 2>/dev/null || true)" != "$old_hash" ]] || ! validate_bundle "$destination"; then
      if ! write_journal "$transaction" rollback-failed "$old_hash" "$new_hash"; then
        echo "Rollback-validation journal update failed; transaction preserved" >&2
      fi
      echo "ROLLBACK VALIDATION FAILED; transaction preserved at: $transaction" >&2
      preserve_transaction=1
      rm -rf "$atomic_tool_dir"
      exit 6
    fi
    if ! write_journal "$transaction" swapped "$old_hash" "$new_hash"; then
      echo "Rollback succeeded but journal update failed; transaction preserved: $transaction" >&2
      rm -rf "$atomic_tool_dir"
      exit 6
    fi
  elif [[ "$new_install_renamed" -eq 1 ]]; then
    if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_ROLLBACK_MOVE:-0}" == 1 ]] || ! mv "$destination" "$staging"; then
      if ! write_journal "$transaction" rollback-failed "$old_hash" "$new_hash"; then
        echo "Rollback-move journal update failed; transaction preserved" >&2
      fi
      echo "ROLLBACK MOVE FAILED; transaction preserved at: $transaction" >&2
      rm -rf "$atomic_tool_dir"
      exit 6
    fi
    new_install_renamed=0
  fi
  if ! safe_cleanup_transaction "$transaction" "$destination_parent"; then
    echo "Rollback succeeded but transaction cleanup failed; preserved at: $transaction" >&2
    rm -rf "$atomic_tool_dir"
    exit 6
  fi
  rm -rf "$atomic_tool_dir"
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
new_hash="$(executable_hash "$staging")"
if [[ "$destination_exists" -eq 1 ]]; then
  old_hash="$(executable_hash "$destination")"
fi
record_journal_or_preserve "$transaction" prepared "$old_hash" "$new_hash" || exit 6

if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_PHASE:-}" == prepared-kill ]]; then
  preserve_transaction=1
  trap - EXIT INT TERM
  rm -rf "$atomic_tool_dir"
  echo "Injected termination after prepared journal: $transaction" >&2
  exit 86
fi

if [[ "$destination_exists" -eq 1 ]]; then
  "$atomic_tool" "$destination" "$staging"
  swap_completed=1
else
  mv "$staging" "$destination"
  new_install_renamed=1
fi

if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_PHASE:-}" == swapped-kill ]]; then
  /bin/kill -9 $$
fi
record_journal_or_preserve "$transaction" swapped "$old_hash" "$new_hash" || exit 6

if [[ "${TMUX_ROOMS_INSTALLER_TESTING:-0}" == 1 && "${TMUX_ROOMS_TEST_FAIL_PHASE:-}" == final ]]; then
  echo "Injected final verification failure" >&2
  exit 5
fi
validate_bundle "$destination" || exit 5

record_journal_or_preserve "$transaction" committed "$old_hash" "$new_hash" || exit 6
safe_cleanup_transaction "$transaction" "$destination_parent" || {
  preserve_transaction=1
  echo "Committed transaction cleanup failed; preserved at: $transaction" >&2
  exit 6
}
transaction_complete=1
swap_completed=0
new_install_renamed=0
trap - EXIT INT TERM
rm -rf "$atomic_tool_dir"

if [[ "$launch_after_install" -eq 1 ]]; then
  open "$destination"
fi
echo "Installed: $destination"
