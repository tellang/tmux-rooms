#!/bin/bash
# Removes Tmux Rooms from this Mac. Compatible with the macOS system bash 3.2.
# tmux, its sessions, and its configuration are never touched.
set -euo pipefail

dry_run=0
assume_yes=0
bundle_id="com.tellang.tmuxrooms"

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [options]

Quit Tmux Rooms and remove the app, the tmuxrooms command, and the files the
app writes. Only these exact paths are considered:

  /Applications/Tmux Rooms.app
  ~/Applications/Tmux Rooms.app
  ~/.local/bin/tmuxrooms
  ~/.local/bin/tmr            (only when it is a link to tmuxrooms)
  ~/Library/Application Support/Tmux Rooms
  ~/Library/Application Support/iTerm2/Scripts/com.tellang.tmuxrooms-title.py
  ~/Library/LaunchAgents/com.tellang.tmux-rooms.plist   (unloaded first)
  ~/.local/state/tmux-rooms   (login item logs)

tmux sessions are left alone. Tabs the app opened in iTerm keep running until
you close them.

Options:
  --dry-run   list what would be removed and change nothing
  --yes       do not ask for confirmation
  --help      show this help
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --yes) assume_yes=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

[[ "$HOME" == /* && "$HOME" != "/" && -d "$HOME" ]] || { echo "HOME must be an absolute directory other than /" >&2; exit 3; }
home="$(cd "$HOME" && pwd -P)"
[[ "$home" != "/" ]] || { echo "HOME resolves to /" >&2; exit 3; }

bin_dir="$home/.local/bin"
launch_agent="$home/Library/LaunchAgents/com.tellang.tmux-rooms.plist"

# Planned removals, kept as parallel arrays because bash 3.2 has no maps.
plan_paths=()
plan_kinds=()
refused=0

plan() { plan_paths+=("$1"); plan_kinds+=("$2"); }
refuse() { echo "Refusing to remove $1: $2" >&2; refused=1; }

# The path's directory must physically be the expected one, so a symlinked
# parent can never redirect a removal somewhere else.
parent_is() {
  local path="$1" expected="$2" parent actual
  parent="$(dirname "$path")"
  [[ -d "$parent" ]] || return 1
  actual="$(cd "$parent" && pwd -P)" || return 1
  [[ "$actual" == "$expected" ]]
}

consider_app() {
  local path="$1" expected_parent="$2" found
  [[ -e "$path" || -L "$path" ]] || return 0
  parent_is "$path" "$expected_parent" || { refuse "$path" "its folder is not $expected_parent"; return 0; }
  if [[ -L "$path" ]]; then
    plan "$path" link
  elif [[ -d "$path" ]]; then
    found="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$found" == "$bundle_id" ]] || { refuse "$path" "bundle identifier is '$found', not $bundle_id"; return 0; }
    plan "$path" directory
  else
    refuse "$path" "not an app bundle"
  fi
}

consider_file() {
  local path="$1" expected_parent="$2"
  [[ -e "$path" || -L "$path" ]] || return 0
  parent_is "$path" "$expected_parent" || { refuse "$path" "its folder is not $expected_parent"; return 0; }
  if [[ -L "$path" ]]; then
    plan "$path" link
  elif [[ -f "$path" ]]; then
    plan "$path" file
  else
    refuse "$path" "not a regular file"
  fi
}

consider_directory() {
  local path="$1" expected_parent="$2"
  [[ -e "$path" || -L "$path" ]] || return 0
  parent_is "$path" "$expected_parent" || { refuse "$path" "its folder is not $expected_parent"; return 0; }
  if [[ -L "$path" ]]; then
    plan "$path" link
  elif [[ -d "$path" ]]; then
    plan "$path" directory
  else
    refuse "$path" "not a directory"
  fi
}

consider_short_link() {
  local path="$bin_dir/tmr" target
  [[ -e "$path" || -L "$path" ]] || return 0
  parent_is "$path" "$bin_dir" || { refuse "$path" "its folder is not $bin_dir"; return 0; }
  target="$(readlink "$path" 2>/dev/null || true)"
  if [[ -L "$path" && ( "$target" == "tmuxrooms" || "$target" == "$bin_dir/tmuxrooms" || "$target" == "$HOME/.local/bin/tmuxrooms" ) ]]; then
    plan "$path" link
  else
    echo "Leaving $path alone: it is not a link to tmuxrooms"
  fi
}

[[ "$(cd /Applications 2>/dev/null && pwd -P)" == /Applications ]] && consider_app "/Applications/Tmux Rooms.app" /Applications
consider_app "$home/Applications/Tmux Rooms.app" "$home/Applications"
consider_file "$bin_dir/tmuxrooms" "$bin_dir"
consider_short_link
consider_directory "$home/Library/Application Support/Tmux Rooms" "$home/Library/Application Support"
consider_file "$home/Library/Application Support/iTerm2/Scripts/com.tellang.tmuxrooms-title.py" "$home/Library/Application Support/iTerm2/Scripts"
consider_file "$launch_agent" "$home/Library/LaunchAgents"
consider_directory "$home/.local/state/tmux-rooms" "$home/.local/state"

app_running=0
if /usr/bin/pgrep -xq TmuxRooms; then
  app_running=1
fi

if [[ "${#plan_paths[@]}" -eq 0 ]]; then
  echo "Nothing to remove."
  exit "$((refused * 3))"
fi

verb="Will remove"
[[ "$dry_run" -eq 0 ]] || verb="Would remove"
[[ "$app_running" -eq 0 ]] || { [[ "$dry_run" -eq 1 ]] && echo "Would quit Tmux Rooms" || echo "Tmux Rooms is running and will be quit first"; }
for index in "${!plan_paths[@]}"; do
  path="${plan_paths[$index]}"
  if [[ "$path" == "$launch_agent" ]]; then
    echo "$verb (after unloading): $path"
  else
    echo "$verb (${plan_kinds[$index]}): $path"
  fi
done

if [[ "$dry_run" -eq 1 ]]; then
  echo "Dry run: nothing was changed."
  exit "$((refused * 3))"
fi

if [[ "$assume_yes" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Refusing to uninstall without --yes when not attached to a terminal" >&2
    exit 2
  fi
  printf 'Type "yes" to remove the items above: ' >&2
  read -r answer
  [[ "$answer" == "yes" ]] || { echo "Uninstall cancelled." >&2; exit 2; }
fi

if [[ "$app_running" -eq 1 ]]; then
  /usr/bin/osascript -e 'quit app "Tmux Rooms"' >/dev/null 2>&1 || true
fi

for index in "${!plan_paths[@]}"; do
  path="${plan_paths[$index]}"
  if [[ "$path" == "$launch_agent" ]]; then
    /bin/launchctl bootout "gui/$(id -u)" "$path" >/dev/null 2>&1 || true
  fi
  case "${plan_kinds[$index]}" in
    directory) /bin/rm -rf -- "$path" ;;
    file|link) /bin/rm -f -- "$path" ;;
  esac
  echo "Removed: $path"
done

if /usr/bin/pgrep -xq TmuxRooms; then
  echo "note: Tmux Rooms is still running; quit it from its menu bar icon." >&2
fi
exit "$((refused * 3))"
