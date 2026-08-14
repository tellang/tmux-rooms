#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$repo_root/scripts/install-local.sh"
identity="Tmux Rooms Local Development"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-rooms-installer.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'remoteInfo = "tmuxrooms-launch"' "$repo_root/TmuxRooms.xcodeproj/project.pbxproj" || fail "launcher build-order dependency is missing"
if grep -q 'tmuxrooms-launch in Resources' "$repo_root/TmuxRooms.xcodeproj/project.pbxproj"; then
  fail "launcher is still copied into Resources"
fi

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
print("fixture")
SWIFT
xcrun swiftc "$tmp/main.swift" -o "$tmp/fixture-bin"

# A second untrusted self-signed identity deliberately reuses the exact CN.
cat >"$tmp/alternate-openssl.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Tmux Rooms Local Development
O=Alternate Fixture
OU=Installer Test
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$tmp/alternate-openssl.cnf" \
  -out "$tmp/alternate-cert.pem" -keyout "$tmp/alternate-key.pem" >/dev/null 2>&1
alternate_fingerprint="$(openssl x509 -in "$tmp/alternate-cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"

write_entitlements() {
  local path="$1" kind="$2"
  case "$kind" in
    app)
      cat >"$path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/></dict></plist>
PLIST
      ;;
    app-get-task)
      cat >"$path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
      ;;
    helper-extra)
      cat >"$path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
      ;;
  esac
}

make_app() {
  local path="$1" version="$2" helper_mode="${3:-valid}" app_mode="${4:-app}"
  mkdir -p "$path/Contents/MacOS" "$path/Contents/Helpers"
  cp "$tmp/fixture-bin" "$path/Contents/MacOS/TmuxRooms"
  cp "$tmp/fixture-bin" "$path/Contents/Helpers/tmuxrooms-launch"
  cat >"$path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TmuxRooms</string>
<key>CFBundleIdentifier</key><string>com.tellang.tmuxrooms</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
  local app_ent="$tmp/app-$RANDOM.plist"
  if [[ "$app_mode" == alternate-cert ]]; then
    write_entitlements "$app_ent" app
  else
    write_entitlements "$app_ent" "$app_mode"
  fi
  case "$helper_mode" in
    valid) codesign --force --sign "$identity" --options runtime --timestamp=none "$path/Contents/Helpers/tmuxrooms-launch" >/dev/null ;;
    adhoc) codesign --force --sign - --options runtime --timestamp=none "$path/Contents/Helpers/tmuxrooms-launch" >/dev/null ;;
    no-runtime) codesign --force --sign "$identity" --timestamp=none "$path/Contents/Helpers/tmuxrooms-launch" >/dev/null ;;
    weak-requirement)
      codesign --force --sign "$identity" --options runtime --timestamp=none \
        -r='designated => identifier "tmuxrooms-launch"' "$path/Contents/Helpers/tmuxrooms-launch" >/dev/null
      ;;
    extra-entitlement)
      local helper_ent="$tmp/helper-$RANDOM.plist"
      write_entitlements "$helper_ent" helper-extra
      codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements "$helper_ent" "$path/Contents/Helpers/tmuxrooms-launch" >/dev/null
      ;;
  esac
  codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements "$app_ent" "$path" >/dev/null
}

run_expect() {
  local expected="$1" label="$2"
  shift 2
  set +e
  "$@" >"$tmp/$label.log" 2>&1
  local status=$?
  set -e
  [[ "$status" -eq "$expected" ]] || { cat "$tmp/$label.log" >&2; fail "$label expected exit $expected, got $status"; }
}

source_app="$tmp/source/Tmux Rooms.app"
old_app="$tmp/install/Tmux Rooms.app"
make_app "$source_app" 2
make_app "$old_app" 1

# Dry-run validates but never needs replacement approval and never mutates.
"$installer" --app-path "$source_app" --destination "$old_app" --dry-run --non-interactive --no-launch >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$old_app/Contents/Info.plist")" == 1 ]] || fail "dry-run mutated existing app"
mkdir -p "$tmp/atomic-build-failure"
run_expect 4 atomic-compile-failure env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_ATOMIC_BUILD=clang \
  "$installer" --app-path "$source_app" --destination "$tmp/atomic-build-failure/Tmux Rooms.app" --dry-run --non-interactive --no-launch

# A real replacement still requires explicit approval.
run_expect 2 refusal "$installer" --app-path "$source_app" --destination "$old_app" --non-interactive --no-launch
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$old_app/Contents/Info.plist")" == 1 ]] || fail "refusal mutated existing app"

# Destination safety rejects non-app/arbitrary, relative, home, repo, symlink, dangling, and overlap paths.
mkdir -p "$tmp/arbitrary-directory"
run_expect 3 arbitrary "$installer" --app-path "$source_app" --destination "$tmp/arbitrary-directory" --yes --non-interactive --no-launch
[[ -d "$tmp/arbitrary-directory" ]] || fail "arbitrary directory was deleted"
run_expect 3 relative "$installer" --app-path "$source_app" --destination 'relative/Tmux Rooms.app' --dry-run --non-interactive --no-launch
run_expect 3 home "$installer" --app-path "$source_app" --destination "$HOME" --dry-run --non-interactive --no-launch
fake_home="$tmp/fake-home"
mkdir -p "$fake_home/Applications"
env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_HOME="$fake_home" \
  "$installer" --app-path "$source_app" --destination "$fake_home/Applications/Tmux Rooms.app" --dry-run --non-interactive --no-launch >/dev/null
run_expect 3 repo "$installer" --app-path "$source_app" --destination "$repo_root/Tmux Rooms.app" --dry-run --non-interactive --no-launch
mkdir -p "$tmp/symlink-case" "$tmp/dangling-case"
ln -s "$old_app" "$tmp/symlink-case/Tmux Rooms.app"
run_expect 3 symlink "$installer" --app-path "$source_app" --destination "$tmp/symlink-case/Tmux Rooms.app" --yes --non-interactive --no-launch
[[ -L "$tmp/symlink-case/Tmux Rooms.app" && -d "$old_app" ]] || fail "destination symlink or target was mutated"
ln -s "$tmp/missing-target.app" "$tmp/dangling-case/Tmux Rooms.app"
run_expect 3 dangling "$installer" --app-path "$source_app" --destination "$tmp/dangling-case/Tmux Rooms.app" --yes --non-interactive --no-launch
[[ -L "$tmp/dangling-case/Tmux Rooms.app" ]] || fail "dangling destination symlink was mutated"
run_expect 3 same "$installer" --app-path "$source_app" --destination "$source_app" --yes --non-interactive --no-launch
mkdir -p "$source_app/Contents/overlap"
run_expect 3 nested "$installer" --app-path "$source_app" --destination "$source_app/Contents/overlap/Tmux Rooms.app" --yes --non-interactive --no-launch

# An arbitrary directory disguised with .app is never a replacement candidate.
fake_app="$tmp/fake/Tmux Rooms.app"
mkdir -p "$fake_app"
printf 'preserve\n' >"$fake_app/marker"
run_expect 3 fake-app "$installer" --app-path "$source_app" --destination "$fake_app" --yes --non-interactive --no-launch
[[ -f "$fake_app/marker" ]] || fail "unsigned fake app was deleted"

# Source signature policy: helper must be non-ad-hoc, runtime, same certificate-bound DR, and entitlement-free.
for mode in adhoc no-runtime weak-requirement extra-entitlement; do
  bad="$tmp/bad-$mode/Tmux Rooms.app"
  make_app "$bad" 2 "$mode"
  mkdir -p "$tmp/out-$mode"
  run_expect 4 "helper-$mode" "$installer" --app-path "$bad" --destination "$tmp/out-$mode/Tmux Rooms.app" --yes --non-interactive --no-launch
done
bad_app="$tmp/bad-get-task/Tmux Rooms.app"
make_app "$bad_app" 2 valid app-get-task
mkdir -p "$tmp/out-get-task"
run_expect 4 get-task "$installer" --app-path "$bad_app" --destination "$tmp/out-get-task/Tmux Rooms.app" --yes --non-interactive --no-launch
mkdir -p "$tmp/out-same-cn"
run_expect 4 same-cn-fingerprint env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_EXPECTED_FINGERPRINT="$alternate_fingerprint" \
  "$installer" --app-path "$source_app" --destination "$tmp/out-same-cn/Tmux Rooms.app" --yes --non-interactive --no-launch

# Injected staging/final verification failures preserve and roll back the existing app.
for phase in staging final; do
  rollback="$tmp/rollback-$phase/Tmux Rooms.app"
  make_app "$rollback" 1
  run_expect 5 "rollback-$phase" env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_PHASE="$phase" \
    "$installer" --app-path "$source_app" --destination "$rollback" --yes --non-interactive --no-launch
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$rollback/Contents/Info.plist")" == 1 ]] || fail "$phase failure did not preserve version 1"
  codesign --verify --deep --strict "$rollback"
done

# Persistent transaction recovery covers termination before swap, after swap before state, and preserved rollback failure.
prepared="$tmp/recovery-prepared/Tmux Rooms.app"
make_app "$prepared" 1
run_expect 86 prepared-kill env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_PHASE=prepared-kill \
  "$installer" --app-path "$source_app" --destination "$prepared" --yes --non-interactive --no-launch
find "$(dirname "$prepared")" -maxdepth 1 -name '.tmux-rooms-transaction.*' | grep -q . || fail "prepared transaction was not preserved"
"$installer" --app-path "$source_app" --destination "$prepared" --yes --non-interactive --no-launch >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$prepared/Contents/Info.plist")" == 2 ]] || fail "prepared recovery did not complete install"
! find "$(dirname "$prepared")" -maxdepth 1 -name '.tmux-rooms-transaction.*' | grep -q . || fail "prepared recovery left transaction residue"

first_install="$tmp/recovery-first-install/Tmux Rooms.app"
mkdir -p "$(dirname "$first_install")"
run_expect 86 first-install-prepared env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_PHASE=prepared-kill \
  "$installer" --app-path "$source_app" --destination "$first_install" --yes --non-interactive --no-launch
[[ ! -e "$first_install" ]] || fail "first-install prepared injection unexpectedly created destination"
first_txn="$(find "$(dirname "$first_install")" -maxdepth 1 -name '.tmux-rooms-transaction.*' -print -quit)"
[[ -d "$first_txn/Tmux Rooms.app" ]] || fail "first-install prepared staging was not preserved"
grep -q '^old_hash=NONE$' "$first_txn/journal" || fail "first-install journal old_hash is not NONE"
"$installer" --app-path "$source_app" --destination "$first_install" --yes --non-interactive --no-launch >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$first_install/Contents/Info.plist")" == 2 ]] || fail "first-install prepared recovery did not install version 2"
! find "$(dirname "$first_install")" -maxdepth 1 -name '.tmux-rooms-transaction.*' | grep -q . || fail "first-install recovery left transaction residue"

swapped="$tmp/recovery-swapped/Tmux Rooms.app"
make_app "$swapped" 1
run_expect 137 swapped-kill env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_PHASE=swapped-kill \
  "$installer" --app-path "$source_app" --destination "$swapped" --yes --non-interactive --no-launch
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$swapped/Contents/Info.plist")" == 2 ]] || fail "swap injection did not leave new app at destination"
"$installer" --app-path "$source_app" --destination "$swapped" --dry-run --non-interactive --no-launch >/dev/null
! find "$(dirname "$swapped")" -maxdepth 1 -name '.tmux-rooms-transaction.*' | grep -q . || fail "swapped recovery left transaction residue"

rollback_failed="$tmp/recovery-rollback-failed/Tmux Rooms.app"
make_app "$rollback_failed" 1
run_expect 6 rollback-swap-failed env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_PHASE=final TMUX_ROOMS_TEST_FAIL_ROLLBACK_SWAP=1 \
  "$installer" --app-path "$source_app" --destination "$rollback_failed" --yes --non-interactive --no-launch
txn_path="$(find "$(dirname "$rollback_failed")" -maxdepth 1 -name '.tmux-rooms-transaction.*' -print -quit)"
[[ -n "$txn_path" && -d "$txn_path/Tmux Rooms.app" ]] || fail "rollback failure did not preserve original backup transaction"
grep -q 'rollback-failed' "$txn_path/journal" || fail "rollback failure journal state missing"
run_expect 6 rollback-residual "$installer" --app-path "$source_app" --destination "$rollback_failed" --dry-run --non-interactive --no-launch
[[ -d "$txn_path/Tmux Rooms.app" ]] || fail "recovery rerun deleted rollback-failed original"

journal_failed="$tmp/recovery-journal-failed/Tmux Rooms.app"
make_app "$journal_failed" 1
run_expect 6 journal-rename-and-rollback-failed env TMUX_ROOMS_INSTALLER_TESTING=1 TMUX_ROOMS_TEST_FAIL_PHASE=final \
  TMUX_ROOMS_TEST_FAIL_ROLLBACK_SWAP=1 TMUX_ROOMS_TEST_FAIL_JOURNAL_PHASE=rollback-failed TMUX_ROOMS_TEST_FAIL_JOURNAL_STEP=rename \
  "$installer" --app-path "$source_app" --destination "$journal_failed" --yes --non-interactive --no-launch
journal_txn="$(find "$(dirname "$journal_failed")" -maxdepth 1 -name '.tmux-rooms-transaction.*' -print -quit)"
[[ -d "$journal_txn/Tmux Rooms.app" && -f "$journal_txn/journal.new" ]] || fail "journal rename failure did not preserve original and journal.new"
run_expect 6 journal-new-residual "$installer" --app-path "$source_app" --destination "$journal_failed" --dry-run --non-interactive --no-launch
[[ -d "$journal_txn/Tmux Rooms.app" && -f "$journal_txn/journal.new" ]] || fail "rerun deleted incomplete journal transaction"

# Successful explicit replacement installs version 2 and the exact helper path only.
"$installer" --app-path "$source_app" --destination "$old_app" --yes --non-interactive --no-launch >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$old_app/Contents/Info.plist")" == 2 ]] || fail "approved replacement did not install version 2"
[[ -x "$old_app/Contents/Helpers/tmuxrooms-launch" ]] || fail "approved install omitted exact helper"
[[ ! -e "$old_app/Contents/Resources/tmuxrooms-launch" ]] || fail "helper was duplicated into Resources"

echo "PASS: destination boundaries, dry-run, signing policy, entitlement allowlists, and rollback transaction"
