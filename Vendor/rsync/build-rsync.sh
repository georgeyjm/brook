#!/bin/zsh
# Builds the rsync helper that ships inside the app as a universal (arm64 + x86_64) binary.
#
#   Vendor/rsync/build-rsync.sh            → Vendor/rsync/out/rsync
#
# rsync is GPLv3. It runs as a separate executable, and we publish this script, the pinned
# version and the upstream source link (see README in this folder) to meet the license.
set -euo pipefail

HERE="${0:A:h}"
source "$HERE/VERSION"   # RSYNC_VERSION, RSYNC_SHA256, RSYNC_URL
BUILD="$HERE/build"
OUT="$HERE/out"
TARBALL="$BUILD/rsync-$RSYNC_VERSION.tar.gz"
MIN_MACOS="${MIN_MACOS:-26.0}"

mkdir -p "$BUILD" "$OUT"

if [[ ! -f "$TARBALL" ]]; then
  echo "→ Downloading rsync $RSYNC_VERSION"
  curl -fsSL "$RSYNC_URL" -o "$TARBALL.part"
  mv "$TARBALL.part" "$TARBALL"
fi

echo "→ Verifying checksum"
actual=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
if [[ "$actual" != "$RSYNC_SHA256" ]]; then
  echo "✗ SHA-256 mismatch for $TARBALL" >&2
  echo "  expected $RSYNC_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

# Optional signature check when the maintainer's key is already in the keyring.
if command -v gpg >/dev/null; then
  if curl -fsSL "$RSYNC_URL.asc" -o "$TARBALL.asc" 2>/dev/null && gpg --verify "$TARBALL.asc" "$TARBALL" 2>/dev/null; then
    echo "→ GPG signature OK"
  else
    echo "  (GPG signature not verified: import the rsync maintainer key to enable this check)"
  fi
fi

build_arch() {
  local arch=$1
  local dir="$BUILD/$arch"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xzf "$TARBALL" -C "$dir" --strip-components=1
  echo "→ Building $arch"
  (
    cd "$dir"
    # No third-party libraries: keeps the helper self-contained. xxhash/zstd/lz4 only add
    # faster checksums/compression; rsync negotiates fallbacks with any peer.
    CFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -O2" \
    LDFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
    ./configure --host="$( [[ $arch == arm64 ]] && echo aarch64 || echo x86_64 )-apple-darwin" \
      --disable-openssl --disable-xxhash --disable-zstd --disable-lz4 --disable-idn --disable-md2man \
      --disable-debug --quiet >/dev/null
    make -j"$(sysctl -n hw.ncpu)" rsync >/dev/null
  )
}

build_arch arm64
build_arch x86_64

lipo -create "$BUILD/arm64/rsync" "$BUILD/x86_64/rsync" -output "$OUT/rsync"
chmod 755 "$OUT/rsync"
cp "$BUILD/arm64/COPYING" "$OUT/COPYING"
echo "✓ $OUT/rsync"
lipo -info "$OUT/rsync"
"$OUT/rsync" --version | head -1
