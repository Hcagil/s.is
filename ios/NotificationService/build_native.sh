#!/bin/bash
# Xcode run-script phase of the NotificationService target: builds the two static libraries the extension links
# (the Rust crate with the peek C API, and SQLite3 Multiple Ciphers that opens the app's encrypted store).
set -euo pipefail

OUT="$DERIVED_FILE_DIR/native"
mkdir -p "$OUT/$PLATFORM_NAME" "$OUT/include" "$OUT/src"
# Xcode's PATH does not hold rustup's cargo.
export PATH="$HOME/.cargo/bin:$PATH"

# Part 1: Rust (always release: the crypto is far too slow in a debug build for a 30 s extension)
echo "Building the Rust library..."
if ! command -v cargo > /dev/null 2>&1; then
  echo "error: cargo not found; install Rust (rustup)" >&2
  exit 1
fi
RUST_LIB_DEST="$OUT/$PLATFORM_NAME/librust_lib_sis.a"
RUST_TARGET_DIR="$OUT/rust-target"
ARCHS_ARRAY=($ARCHS)
RUST_LIBS=()
for arch in "${ARCHS_ARRAY[@]}"; do
  case "$PLATFORM_NAME-$arch" in
    iphoneos-arm64) triple="aarch64-apple-ios" ;;
    iphonesimulator-arm64) triple="aarch64-apple-ios-sim" ;;
    iphonesimulator-x86_64) triple="x86_64-apple-ios" ;;
    *)
      echo "error: unsupported platform and architecture: $PLATFORM_NAME-$arch" >&2
      exit 1
      ;;
  esac
  if command -v rustup > /dev/null 2>&1; then
    rustup target add "$triple"
  fi
  CARGO_TARGET_DIR="$RUST_TARGET_DIR" cargo build --release --locked --target "$triple" --manifest-path "$SRCROOT/../rust/Cargo.toml"
  RUST_LIBS+=("$RUST_TARGET_DIR/$triple/release/librust_lib_sis.a")
done
if [ "${#RUST_LIBS[@]}" -eq 1 ]; then
  cp "${RUST_LIBS[0]}" "$RUST_LIB_DEST"
else
  lipo -create "${RUST_LIBS[@]}" -output "$RUST_LIB_DEST"
fi

# Part 2: SQLite3 Multiple Ciphers. Pinned to the version the Dart sqlite3 package 3.7.1 ships, so both open the same file format.
# Needs the network at build time, like the sqlite3 build hook of the app.
VERSION="2.6.1"
SQLITE="3.54.0"
SHA256="3f25af603566a23c821d8e581778b5ece2a541d2435776de57b8d845c176815a"
URL="https://github.com/utelle/SQLite3MultipleCiphers/releases/download/v${VERSION}/sqlite3mc-${VERSION}-sqlite-${SQLITE}-amalgamation.zip"
STAMP="$OUT/src/stamp-$VERSION"
if [ ! -f "$STAMP" ]; then
  echo "Fetching SQLite3 Multiple Ciphers $VERSION..."
  rm -rf "$OUT/src"
  mkdir -p "$OUT/src"
  curl -fsSL --retry 3 -o "$OUT/src/amalgamation.zip" "$URL"
  echo "$SHA256  $OUT/src/amalgamation.zip" | shasum -a 256 -c -
  unzip -q -o "$OUT/src/amalgamation.zip" sqlite3mc_amalgamation.c sqlite3.h -d "$OUT/src"
  touch "$STAMP"
fi
cp "$OUT/src/sqlite3.h" "$OUT/include/sqlite3.h"

SQLITE_LIB_DEST="$OUT/$PLATFORM_NAME/libsqlite3mc.a"
if [ ! -f "$SQLITE_LIB_DEST" ] || [ "$STAMP" -nt "$SQLITE_LIB_DEST" ]; then
  echo "Building SQLite3 Multiple Ciphers..."
  if [ "$PLATFORM_NAME" = "iphoneos" ]; then
    MIN_VERSION_FLAG="-mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
  else
    MIN_VERSION_FLAG="-mios-simulator-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
  fi
  ARCHIVES=()
  for arch in "${ARCHS_ARRAY[@]}"; do
    xcrun --sdk "$PLATFORM_NAME" clang -c -O2 -w -arch "$arch" -isysroot "$SDKROOT" "$MIN_VERSION_FLAG" \
      -DSQLITE_THREADSAFE=1 -DSQLITE_TEMP_STORE=2 -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION \
      -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_DEPRECATED \
      "$OUT/src/sqlite3mc_amalgamation.c" -o "$OUT/src/sqlite3mc-$PLATFORM_NAME-$arch.o"
    libtool -static -o "$OUT/src/libsqlite3mc-$PLATFORM_NAME-$arch.a" "$OUT/src/sqlite3mc-$PLATFORM_NAME-$arch.o"
    ARCHIVES+=("$OUT/src/libsqlite3mc-$PLATFORM_NAME-$arch.a")
  done
  if [ "${#ARCHIVES[@]}" -eq 1 ]; then
    cp "${ARCHIVES[0]}" "$SQLITE_LIB_DEST"
  else
    lipo -create "${ARCHIVES[@]}" -output "$SQLITE_LIB_DEST"
  fi
fi
