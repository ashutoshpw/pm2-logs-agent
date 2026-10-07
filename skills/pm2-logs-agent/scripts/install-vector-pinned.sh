#!/usr/bin/env bash
# pm2-logs-agent — install the pinned Vector version
#
# Installs an EXACT Vector version with a checksum gate, so the config in this
# repo is validated against the binary that actually runs.
#
# Why not `apt-get install vector`: that installs whatever is newest in the repo.
# The pin is the point — a config that validates on 0.59.0 may not on 0.61, and
# silently validating against a different binary makes the check meaningless.
#
# Usage:
#   install-vector-pinned.sh [--dry-run] [--method deb|tarball] [--force]
#
# Requires root (or a container with write access to /usr/bin).
# Exit: 0 ok, 1 usage/env error, 2 checksum mismatch, 3 install failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
[ -f "$REPO_DIR/assets/vector-version.env" ] && . "$REPO_DIR/assets/vector-version.env"

V="${VECTOR_VERSION:-}"
FLOOR="${VECTOR_KNOWN_GOOD_FLOOR:-}"
METHOD="auto"
DRY_RUN="no"
FORCE="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="yes"; shift ;;
    --method)  METHOD="${2:-auto}"; shift 2 ;;
    --force)   FORCE="yes"; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install-vector-pinned: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$V" ] || { printf 'install-vector-pinned: VECTOR_VERSION unset in assets/vector-version.env\n' >&2; exit 1; }

die() { printf 'install-vector-pinned: %s\n' "$2" >&2; exit "${1:-1}"; }

# ---------------------------------------------------------------------------
# detect architecture and libc
# ---------------------------------------------------------------------------
# Release assets are built per arch AND per libc, so the wrong pick fails late
# with an exec-format or GLIBC error rather than at download time.

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH_TAG="x86_64"; DEB_ARCH="amd64"; TARBALL_ARCH="x86_64-unknown-linux" ;;
  aarch64|arm64) ARCH_TAG="aarch64"; DEB_ARCH="arm64"; TARBALL_ARCH="aarch64-unknown-linux" ;;
  armv7l)        ARCH_TAG="armv7";  DEB_ARCH="armhf"; TARBALL_ARCH="armv7-unknown-linux" ;;
  armv6l)        ARCH_TAG="armv6";  DEB_ARCH="armel"; TARBALL_ARCH="arm-unknown-linux-gnueabi" ;;
  *) die 1 "unsupported architecture: $ARCH" ;;
esac

# musl (Alpine) vs glibc (Debian/RHEL). `ldd --version` says "musl" on Alpine.
LIBC="gnu"
if command -v ldd >/dev/null 2>&1; then
  if ldd --version 2>&1 | grep -qi musl; then LIBC="musl"; fi
elif [ -f /etc/alpine-release ]; then
  LIBC="musl"
fi

if [ "$METHOD" = "auto" ]; then
  if [ "$LIBC" = "musl" ] || ! command -v dpkg >/dev/null 2>&1; then
    METHOD="tarball"
  else
    METHOD="deb"
  fi
fi

BASE_URL="https://github.com/vectordotdev/vector/releases/download/v$V"
if [ "$METHOD" = "deb" ]; then
  ASSET="vector_${V}-1_${DEB_ARCH}.deb"
else
  ASSET="vector-${V}-${TARBALL_ARCH}-${LIBC}.tar.gz"
fi
SHA_URL="$BASE_URL/vector-${V}-SHA256SUMS"

printf 'pinned version : %s\n' "$V"
printf 'known-good floor: %s\n' "${FLOOR:-n/a}"
printf 'arch / libc    : %s / %s\n' "$ARCH_TAG" "$LIBC"
printf 'method / asset : %s / %s\n' "$METHOD" "$ASSET"
printf '\n'

if [ "$DRY_RUN" = "yes" ]; then
  printf 'DRY RUN. Would download:\n  %s/%s\n  %s\n' "$BASE_URL" "$ASSET" "$SHA_URL"
  printf '\nExisting install: %s\n' "$(command -v vector >/dev/null 2>&1 && vector --version 2>/dev/null || echo none)"
  exit 0
fi

# Refuse to clobber a different version without --force, so an upgrade is never
# silent. Upgrades are CHANGE tier and need explicit consent.
if command -v vector >/dev/null 2>&1; then
  CUR="$(vector --version 2>/dev/null | awk '{print $2}' | tr -d 'v')"
  if [ "$CUR" != "$V" ] && [ "$FORCE" != "yes" ]; then
    die 1 "Vector $CUR is installed but the pin is $V. Re-run with --force to replace it (CHANGE tier: this replaces a working collector)."
  fi
fi

[ "$(id -u)" = "0" ] || die 1 "must run as root"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'Downloading SHA256SUMS...\n'
if ! curl -fsSL --max-time 60 "$SHA_URL" -o "$TMP/SHA256SUMS"; then
  die 1 "could not fetch $SHA_URL"
fi

printf 'Downloading %s...\n' "$ASSET"
curl -fsSL --max-time 300 "$BASE_URL/$ASSET" -o "$TMP/$ASSET" || die 1 "download failed: $ASSET"

# Verify against the release's own checksum file. This is the gate that makes the
# pin trustworthy: without it, "pinned" just means "whatever the URL served".
EXPECTED="$(awk -v f="$ASSET" '$2 == f || $2 == "*"f {print $1}' "$TMP/SHA256SUMS" | head -1)"
[ -n "$EXPECTED" ] || die 1 "asset '$ASSET' not listed in SHA256SUMS — refusing to install an unverifiable binary"
ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  die 2 "CHECKSUM MISMATCH for $ASSET
  expected $EXPECTED
  actual   $ACTUAL
The download is corrupt or tampered with. Not installing."
fi
printf 'Checksum OK (%s)\n\n' "$ACTUAL"

if [ "$METHOD" = "deb" ]; then
  printf 'Installing via dpkg...\n'
  dpkg -i "$TMP/$ASSET" || die 3 "dpkg install failed. If this is an upgrade, run: apt-get install -f"
else
  BIN_DIR="/usr/bin"
  printf 'Installing to %s/vector...\n' "$BIN_DIR"
  tar -xzf "$TMP/$ASSET" -C "$TMP"
  # The tarball's top-level directory is NOT version-prefixed. Verified for
  # 0.59.0: it extracts to ./vector-x86_64-unknown-linux-gnu/bin/vector, not
  # ./vector-0.59.0-x86_64-unknown-linux-gnu/vector. Locating the binary by
  # pattern rather than by a constructed path avoids that whole class of bug.
  VBIN="$(find "$TMP" -type f -name vector -perm -u+x 2>/dev/null | head -1)"
  [ -n "$VBIN" ] || die 3 "could not find the vector binary inside $ASSET"
  install -m 0755 "$VBIN" "$BIN_DIR/vector" || die 3 "could not install binary to $BIN_DIR"
fi

INSTALLED="$(vector --version 2>/dev/null | awk '{print $2}' | tr -d 'v')"
if [ "$INSTALLED" != "$V" ]; then
  die 3 "post-install version mismatch: expected $V, got ${INSTALLED:-unknown}"
fi

printf '\nInstalled vector %s\n' "$INSTALLED"
if [ -f /etc/vector/vector.yaml ] || [ -f /etc/vector/vector.toml ]; then
  printf '\nNOTE: an existing /etc/vector config was found. Validate the new binary\n'
  printf 'against it before enabling: vector validate --no-environment <config>\n'
fi
exit 0