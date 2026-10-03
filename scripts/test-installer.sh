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
# A fixture app that stays up, so the installer can see a running copy.
cat > "$tmp/sleeper.swift" <<'SWIFT'
import Foundation
sleep(30)
SWIFT
xcrun swiftc "$tmp/sleeper.swift" -o "$tmp/sleeper-bin"
fixture_main_bin="$tmp/fixture-bin"

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
  local path="$1" version="$2" helper_mode="${3:-valid}" app_mode="${4:-app}" app_identity="${5:-$identity}"
  mkdir -p "$path/Contents/MacOS" "$path/Contents/Helpers"
  cp "$fixture_main_bin" "$path/Contents/MacOS/TmuxRooms"
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
  codesign --force --sign "$app_identity" --options runtime --timestamp=none --entitlements "$app_ent" "$path" >/dev/null
}

# Stands in for `security` on PATH so the installer sees a chosen Keychain
# listing. Every other subcommand goes to the real tool.
write_security_shim() {
  local dir="$1" listing="$2"
  mkdir -p "$dir"
  cat >"$dir/security" <<SHIM
#!/bin/bash
if [[ "\${1:-}" == find-identity ]]; then
  printf '%s' '$listing'
  [[ -n '$listing' ]] || exit 1
  exit 0
fi
exec /usr/bin/security "\$@"
SHIM
  chmod 755 "$dir/security"
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
# The Keychain reports a same-CN identity whose certificate is not the one that signed the bundle.
mkdir -p "$tmp/out-same-cn"
write_security_shim "$tmp/shim-same-cn" "  1) $alternate_fingerprint \"$identity\"
     1 valid identities found
"
run_expect 4 same-cn-fingerprint env PATH="$tmp/shim-same-cn:$PATH" \
  "$installer" --app-path "$source_app" --destination "$tmp/out-same-cn/Tmux Rooms.app" --yes --non-interactive --no-launch
real_fingerprint="$(security find-identity -v -p codesigning | awk -v want="\"$identity\"" '{ name = $0; sub(/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]+[[:space:]]+/, "", name) } name == want { print $2 }')"
[[ -n "$real_fingerprint" ]] || fail "cannot read the real identity fingerprint"
write_security_shim "$tmp/shim-duplicate" "  1) $real_fingerprint \"$identity\"
  2) $alternate_fingerprint \"$identity\"
     2 valid identities found
"
run_expect 4 duplicate-identity env PATH="$tmp/shim-duplicate:$PATH" \
  "$installer" --app-path "$source_app" --destination "$tmp/out-same-cn/Tmux Rooms.app" --dry-run --non-interactive --no-launch

# Signing options: --identity, its environment default, --ad-hoc, and their conflict.
mkdir -p "$tmp/out-options"
options_dest="$tmp/out-options/Tmux Rooms.app"
run_expect 64 conflict-identity-first "$installer" --identity "$identity" --ad-hoc \
  --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 64 conflict-ad-hoc-first "$installer" --ad-hoc --identity "$identity" \
  --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
grep -q 'cannot be used together' "$tmp/conflict-ad-hoc-first.log" || fail "conflict did not explain itself"
run_expect 64 identity-missing-name "$installer" --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch --identity
run_expect 64 identity-empty-name "$installer" --identity "" --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 0 identity-explicit "$installer" --identity "$identity" \
  --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 4 identity-absent "$installer" --identity "Tmux Rooms Absent Fixture" \
  --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 4 identity-env-absent env TMUX_ROOMS_SIGNING_IDENTITY="Tmux Rooms Absent Fixture" \
  "$installer" --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 0 identity-env-present env TMUX_ROOMS_SIGNING_IDENTITY="$identity" \
  "$installer" --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
# A chosen name is pinned too: the bundle's Authority must be that name, not just any Keychain identity.
write_security_shim "$tmp/shim-other-name" "  1) $real_fingerprint \"Tmux Rooms Other Fixture\"
     1 valid identities found
"
run_expect 4 identity-authority-mismatch env PATH="$tmp/shim-other-name:$PATH" \
  "$installer" --identity "Tmux Rooms Other Fixture" --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch

# Ad hoc mode never consults the Keychain, so a failing `security` must not matter.
write_security_shim "$tmp/shim-empty" ""
adhoc_app="$tmp/adhoc-source/Tmux Rooms.app"
make_app "$adhoc_app" 2 adhoc app -
run_expect 0 ad-hoc-dry-run env PATH="$tmp/shim-empty:$PATH" \
  "$installer" --ad-hoc --app-path "$adhoc_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
grep -q 'Automation for iTerm' "$tmp/ad-hoc-dry-run.log" || fail "ad hoc mode did not warn about privacy permissions"
[[ ! -e "$options_dest" ]] || fail "ad hoc dry run created the destination"
run_expect 0 ad-hoc-env-overridden env PATH="$tmp/shim-empty:$PATH" TMUX_ROOMS_SIGNING_IDENTITY="Tmux Rooms Absent Fixture" \
  "$installer" --ad-hoc --app-path "$adhoc_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 4 identity-rejects-ad-hoc "$installer" --app-path "$adhoc_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
adhoc_get_task="$tmp/adhoc-get-task/Tmux Rooms.app"
make_app "$adhoc_get_task" 2 adhoc app-get-task -
run_expect 4 ad-hoc-app-entitlements env PATH="$tmp/shim-empty:$PATH" \
  "$installer" --ad-hoc --app-path "$adhoc_get_task" --destination "$options_dest" --dry-run --non-interactive --no-launch
adhoc_helper_extra="$tmp/adhoc-helper-extra/Tmux Rooms.app"
make_app "$adhoc_helper_extra" 2 extra-entitlement app -
run_expect 4 ad-hoc-helper-entitlements env PATH="$tmp/shim-empty:$PATH" \
  "$installer" --ad-hoc --app-path "$adhoc_helper_extra" --destination "$options_dest" --dry-run --non-interactive --no-launch
adhoc_no_runtime="$tmp/adhoc-no-runtime/Tmux Rooms.app"
make_app "$adhoc_no_runtime" 2 no-runtime app -
run_expect 4 ad-hoc-helper-runtime env PATH="$tmp/shim-empty:$PATH" \
  "$installer" --ad-hoc --app-path "$adhoc_no_runtime" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 0 ad-hoc-install env PATH="$tmp/shim-empty:$PATH" \
  "$installer" --ad-hoc --app-path "$adhoc_app" --destination "$options_dest" --non-interactive --no-launch
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$options_dest/Contents/Info.plist")" == 2 ]] || fail "ad hoc install did not install version 2"
codesign --verify --strict "$options_dest/Contents/Helpers/tmuxrooms-launch"

# Login item: --login and --no-login only report in a dry run, and conflict with each other.
fake_login_home="$tmp/login-home"
mkdir -p "$fake_login_home"
login_plist="$fake_login_home/Library/LaunchAgents/com.tellang.tmux-rooms.plist"
# A different HOME also hides the Keychain search list, so list the real identity directly.
write_security_shim "$tmp/shim-real" "  1) $real_fingerprint \"$identity\"
     1 valid identities found
"
run_expect 64 login-conflict "$installer" --login --no-login \
  --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
run_expect 64 login-conflict-reversed "$installer" --no-login --login \
  --app-path "$source_app" --destination "$options_dest" --dry-run --non-interactive --no-launch
grep -q 'cannot be used together' "$tmp/login-conflict-reversed.log" || fail "login conflict did not explain itself"
run_expect 0 login-dry-run env HOME="$fake_login_home" PATH="$tmp/shim-real:$PATH" "$installer" --login \
  --app-path "$source_app" --destination "$old_app" --dry-run --non-interactive
grep -Fq "Dry run would register login item: $login_plist" "$tmp/login-dry-run.log" || fail "login dry run did not report the agent"
grep -Fq "Dry run would launch: " "$tmp/login-dry-run.log" || fail "dry run did not report the launch"
run_expect 0 no-login-dry-run env HOME="$fake_login_home" PATH="$tmp/shim-real:$PATH" "$installer" --no-login \
  --app-path "$source_app" --destination "$old_app" --dry-run --non-interactive --no-launch
grep -Fq "Dry run would remove login item: $login_plist" "$tmp/no-login-dry-run.log" || fail "no-login dry run did not report the agent"
! grep -q 'would launch' "$tmp/no-login-dry-run.log" || fail "--no-launch dry run still reported a launch"
[[ ! -e "$fake_login_home/Library" && ! -e "$fake_login_home/.local" ]] || fail "login dry run wrote files"

# A copy running from the destination is quit and relaunched; a dry run only says so.
fixture_main_bin="$tmp/sleeper-bin"
running_app="$tmp/running/Tmux Rooms.app"
make_app "$running_app" 1
fixture_main_bin="$tmp/fixture-bin"
running_physical="$(cd "$tmp/running" && pwd -P)/Tmux Rooms.app"
"$running_physical/Contents/MacOS/TmuxRooms" &
running_pid=$!
run_expect 0 running-dry-run "$installer" --app-path "$source_app" --destination "$running_app" --dry-run --non-interactive
run_expect 0 running-dry-run-no-launch "$installer" --app-path "$source_app" --destination "$running_app" --dry-run --non-interactive --no-launch
kill "$running_pid" 2>/dev/null || true
wait "$running_pid" 2>/dev/null || true
grep -Fq "would quit the running app (pid $running_pid) and relaunch it" "$tmp/running-dry-run.log" || fail "dry run did not report the restart"
grep -Fq "would quit the running app (pid $running_pid) and leave it closed" "$tmp/running-dry-run-no-launch.log" || fail "--no-launch dry run did not report the quit"
run_expect 0 not-running-dry-run "$installer" --app-path "$source_app" --destination "$running_app" --dry-run --non-interactive --no-launch
! grep -q 'would quit' "$tmp/not-running-dry-run.log" || fail "dry run reported a quit with nothing running"

# install-cli.sh shares the flags; its argument errors exit before any build.
cli_installer="$repo_root/scripts/install-cli.sh"
run_expect 0 cli-help "$cli_installer" --help
grep -q -- '--ad-hoc' "$tmp/cli-help.log" || fail "install-cli help omits --ad-hoc"
run_expect 2 cli-conflict "$cli_installer" --ad-hoc --identity "$identity" --destination "$tmp/cli/tmuxrooms"
grep -q 'cannot be used together' "$tmp/cli-conflict.log" || fail "install-cli conflict did not explain itself"
run_expect 2 cli-identity-missing-name "$cli_installer" --destination "$tmp/cli/tmuxrooms" --identity
[[ ! -e "$tmp/cli" ]] || fail "install-cli argument error touched the destination"

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

echo "PASS: destination boundaries, dry-run, signing policy, signing options, login item, restart on upgrade, entitlement allowlists, and rollback transaction"
