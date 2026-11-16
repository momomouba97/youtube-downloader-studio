#!/usr/bin/env bash
# Fetch matching FFmpeg + FFprobe release binaries for macOS Intel (x86_64).
# Source: Martin Riedl's macOS Intel release builds.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/binaries"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-ffmpeg.XXXXXX")"

# Pin a known Intel macOS release. Override only after checking the provider's
# release page and confirming the binary's minimum macOS deployment target.
VERSION="9.0.2"
BUILD_ID="1789931006_${VERSION}"
BASE_URL="https://ffmpeg.martin-riedl.de/download/macos/amd64/${BUILD_ID}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v unzip >/dev/null 2>&1 || fail "unzip is required."
command -v shasum >/dev/null 2>&1 || fail "shasum is required."
command -v file >/dev/null 2>&1 || fail "'file' is required."
command -v lipo >/dev/null 2>&1 || fail "'lipo' is required (run this on macOS)."

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This script must run on macOS. Current OS: $(uname -s)"
fi

mkdir -p "$BIN_DIR"

download_and_verify() {
  local tool="$1"
  local archive="$TMP_DIR/${tool}.zip"
  local checksum_file="$TMP_DIR/${tool}.zip.sha256"
  local extract_dir="$TMP_DIR/${tool}-extract"
  local expected actual candidate

  local url="${BASE_URL}/${tool}.zip"
  local checksum_url="${url}.sha256"

  echo "Downloading ${tool} ${VERSION} for macOS Intel..."
  curl --fail --location --silent --show-error \
       --retry 4 --retry-all-errors --connect-timeout 30 \
       --output "$archive" "$url"

  [[ -s "$archive" ]] || fail "Downloaded ${tool} archive is empty."
  unzip -tq "$archive" >/dev/null || fail "${tool} archive is not a valid ZIP."

  echo "Fetching SHA256 checksum for ${tool}..."
  curl --fail --location --silent --show-error \
       --retry 4 --retry-all-errors --connect-timeout 30 \
       --output "$checksum_file" "$checksum_url"

  expected="$(grep -Eo '[[:xdigit:]]{64}' "$checksum_file" | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
  [[ -n "$expected" ]] || fail "Could not read a SHA256 checksum from ${checksum_url}"

  actual="$(shasum -a 256 "$archive" | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || fail "SHA256 mismatch for ${tool}. Expected ${expected}, got ${actual}."

  mkdir -p "$extract_dir"
  unzip -oq "$archive" -d "$extract_dir"

  candidate="$(find "$extract_dir" -type f -name "$tool" -print -quit)"
  [[ -n "$candidate" ]] || fail "The ZIP did not contain an executable named ${tool}."
  [[ -x "$candidate" ]] || chmod +x "$candidate"

  local archs
  archs="$(lipo -archs "$candidate" 2>/dev/null || true)"
  [[ " $archs " == *" x86_64 "* ]] || fail "${tool} is not an x86_64 Intel binary (architectures: ${archs:-unknown})."

  install -m 755 "$candidate" "$BIN_DIR/$tool"
  echo "Installed $BIN_DIR/$tool"
  echo "SHA256 verified: $actual"
  file "$BIN_DIR/$tool"
}

download_and_verify ffmpeg
download_and_verify ffprobe

echo
echo "Checking FFmpeg / FFprobe versions..."
"$BIN_DIR/ffmpeg" -version | head -n 1
"$BIN_DIR/ffprobe" -version | head -n 1

# Keep the project's existing Mach-O deployment-target check.
CHECKER="$ROOT/scripts/check_macho.py"
if [[ -f "$CHECKER" ]]; then
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for check_macho.py."
  python3 "$CHECKER" "$BIN_DIR" --min 11.0 --verbose
else
  fail "Missing $CHECKER; cannot verify the macOS 11.0 minimum deployment target."
fi

echo
echo "SUCCESS: Intel FFmpeg and FFprobe downloaded, checksum-verified, and passed the Mach-O check."
