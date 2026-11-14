#!/usr/bin/env bash
# update-claude - Updates the system-wide Claude Code installation.
#   
# Versions are kept in /usr/local/lib/claude-code/versions/,
# /usr/local/bin/claude is a symlink to the active one.
#
# Usage:
#   update-claude --check          # Show installed and available version (no root needed)
#   sudo update-claude             # Install the latest version
#   sudo update-claude stable      # Install from the stable channel
#   sudo update-claude 2.1.322     # Install a specific version (also for rollback)
set -euo pipefail
umask 022

BASE=https://downloads.claude.ai/claude-code-releases
BIN=/usr/local/bin/claude
STORE=/usr/local/lib/claude-code/versions
KEEP=3                                   # Total number of versions to keep
VER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'

die()   { echo "update-claude: $*" >&2; exit 1; }
fetch() { curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --max-time 600 "$@"; }
# Run an untrusted binary as 'nobody' instead of root
run_unpriv() {
  if ((EUID == 0)); then runuser -u nobody -- env -i PATH=/usr/bin:/bin HOME=/nonexistent "$@"
  else "$@"; fi
}

# --- 1. Arguments and dependencies ---
target=latest; check=0
for a in "$@"; do
  case $a in
    --check) check=1 ;;
    latest|stable) target=$a ;;
    *) [[ $a =~ $VER_RE ]] || die "Unknown argument '$a' (usage: update-claude [latest|stable|X.Y.Z] [--check])"
       target=$a ;;
  esac
done
for c in curl jq sha256sum; do
  command -v "$c" >/dev/null || die "Missing '$c' (sudo apt install $c)"
done

# --- 2. Platform (same logic as install.sh) ---
case $(uname -m) in
  x86_64|amd64)  arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
platform=linux-$arch
if [[ $(ldd --version 2>&1 || true) == *musl* ]]; then platform+=-musl; fi

# --- 3. Available and installed versions ---
if [[ $target =~ $VER_RE ]]; then
  version=$target
else
  version=$(fetch "$BASE/$target") || die "Cannot fetch the version for '$target'"
  version=${version//[$'\r\n\t ']/}
  [[ $version =~ $VER_RE ]] || die "Server returned unexpected content instead of a version number"
fi

current=""
if [[ -L $BIN ]]; then
  current=$(basename "$(readlink -f "$BIN")")
elif [[ -x $BIN ]]; then
  current=$(run_unpriv "$BIN" --version 2>/dev/null | awk '{print $1}') || current=""
fi
echo "Installed: ${current:-none}    Available ($target): $version"
((check)) && exit 0

[[ $EUID -eq 0 ]] || die "Must be run with sudo"
[[ $current == "$version" ]] && { echo "Already up to date."; exit 0; }

exec 9>/run/lock/update-claude.lock
flock -n 9 || die "Another update is already running"

# --- 4. Manifest and checksum ---
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
manifest=$(fetch "$BASE/$version/manifest.json") || die "No manifest for version $version"
checksum=$(jq -r --arg p "$platform" '.platforms[$p].checksum // empty' <<<"$manifest")
size=$(jq -r --arg p "$platform" '.platforms[$p].size // empty' <<<"$manifest")
[[ $checksum =~ ^[a-f0-9]{64}$ ]] || die "No checksum for $platform in the manifest"

# --- 5. Download, verify, smoke test ---
install -d -o root -g root -m 755 "$STORE"
if [[ -f $STORE/$version && $(sha256sum "$STORE/$version" | cut -d' ' -f1) == "$checksum" ]]; then
  echo "Version $version is already downloaded and verified."
else
  echo "Downloading $version ($platform)..."
  fetch -o "$tmp/claude" "$BASE/$version/$platform/claude" || die "Download failed"
  [[ -z $size || $(stat -c %s "$tmp/claude") == "$size" ]] || die "File size does not match the manifest"
  [[ $(sha256sum "$tmp/claude" | cut -d' ' -f1) == "$checksum" ]] \
    || die "Checksum MISMATCH, file rejected"
  chmod 755 "$tmp" "$tmp/claude"
  got=$(run_unpriv "$tmp/claude" --version 2>/dev/null | awk '{print $1}') || got=""
  [[ $got == "$version" ]] || die "New binary failed the smoke test (--version returned '${got:-nothing}')"
  install -o root -g root -m 755 "$tmp/claude" "$STORE/$version.new"
  mv -f "$STORE/$version.new" "$STORE/$version"
fi

# --- 6. First run: keep the current plain file as a stored version ---
if [[ -f $BIN && ! -L $BIN ]]; then
  keep=${current:-previous-$(date +%F)}
  [[ -e $STORE/$keep ]] || install -o root -g root -m 755 "$BIN" "$STORE/$keep"
fi

# --- 7. Switch ---
ln -sfn "$STORE/$version" "$BIN.new"
mv -Tf "$BIN.new" "$BIN"
echo "Done: $BIN -> $STORE/$version"

# --- 8. Remove old versions ---
mapfile -t all < <(find "$STORE" -maxdepth 1 -type f ! -name '*.new' -printf '%f\n' | sort -V)
if (( ${#all[@]} > KEEP )); then
  for v in "${all[@]:0:${#all[@]}-KEEP}"; do
    [[ $v == "$version" ]] && continue
    rm -f -- "$STORE/$v"; echo "Removed old version: $v"
  done
fi
