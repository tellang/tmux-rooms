#!/bin/bash
# Builds the Release `tmuxrooms` command and installs it as a single file.
# Compatible with the macOS system bash 3.2.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
build_dir="$repo_root/DerivedData"
destination="$HOME/.local/bin/tmuxrooms"
identity="Tmux Rooms Local Development"

usage() {
  cat <<'EOF'
Usage: scripts/install-cli.sh [options]

Build, sign, and install the tmuxrooms command line tool.

Options:
  --destination PATH   install path (default: ~/.local/bin/tmuxrooms)
  --build-dir PATH     DerivedData directory (default: repo/DerivedData)
  --help               show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination) destination="${2:?--destination needs a path}"; shift 2 ;;
    --build-dir) build_dir="${2:?--build-dir needs a path}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$(basename "$destination")" == "tmuxrooms" ]] || {
  echo "Unsafe destination: file name must be exactly tmuxrooms" >&2
  exit 3
}
[[ ! -d "$destination" ]] || { echo "Unsafe destination: $destination is a directory" >&2; exit 3; }

# The same local identity signs the app and its helper. Without it the tool is
# signed ad hoc, which is enough to run it from a shell on this machine.
if ! security find-identity -v -p codesigning | grep -q "\"$identity\""; then
  echo "note: signing identity \"$identity\" not found; signing ad hoc" >&2
  identity="-"
fi

xcodebuild -quiet -project "$repo_root/TmuxRooms.xcodeproj" -scheme tmuxrooms-cli \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_dir" CODE_SIGN_IDENTITY="$identity" build

built="$build_dir/Build/Products/Release/tmuxrooms"
[[ -x "$built" ]] || { echo "Build produced no tmuxrooms binary: $built" >&2; exit 4; }
/usr/bin/codesign --verify --strict "$built"

mkdir -p "$(dirname "$destination")"
tmp="$(mktemp "$destination.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
/usr/bin/ditto "$built" "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$destination"
trap - EXIT

/usr/bin/codesign --verify --strict "$destination"
echo "Installed $destination"

# `tmr` is the short name. It is a relative link, so a reinstall that replaces
# tmuxrooms is picked up, and anything already named tmr is left alone.
short="$(dirname "$destination")/tmr"
if [[ -e "$short" || -L "$short" ]]; then
  [[ "$(readlink "$short" 2>/dev/null)" == "tmuxrooms" ]] || echo "note: $short already exists; left unchanged" >&2
else
  ln -s tmuxrooms "$short"
  echo "Linked $short"
fi
