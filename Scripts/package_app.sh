#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  cat <<'EOF'
Usage: Scripts/package_app.sh

Build and package dist/ClashBar.app.

Environment:
  APP_NAME=...             App bundle display name.
  BUNDLE_ID=...            App bundle identifier.
  APP_VERSION=...          Version used for Info.plist.
  BUILD_NUMBER=...         Build number used for Info.plist.
  TARGET_ARCH=...          Pass --arch to Swift build.
  BUNDLE_MIHOMO_BINARY=0   Build app without bundled mihomo.
  REQUIRE_MIHOMO_BINARY=0  Allow packaging without a mihomo payload.
  PREPROCESS_DIR=...       Directory containing preprocessed resources.
  PREPROCESSED_ICON_PATH=... Custom preprocessed app icon path.
  PREPROCESSED_MIHOMO_PATH=... Custom preprocessed mihomo path.
  RELEASE_OPTIMIZE_FOR_SIZE=0  Disable -Osize for release build.
  STRIP_BINARIES=0         Keep packaged binaries unstripped.
  CODESIGN_IDENTITY=...    Codesign identity; defaults to ad-hoc.
EOF
}

case "${1:-}" in
  "")
    ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
esac

APP_NAME="${APP_NAME:-ClashBar}"
BUNDLE_ID="${BUNDLE_ID:-com.clashbar}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TARGET_ARCH="${TARGET_ARCH:-}"
RELEASE_OPTIMIZE_FOR_SIZE="${RELEASE_OPTIMIZE_FOR_SIZE:-1}"
STRIP_BINARIES="${STRIP_BINARIES:-1}"
PREPROCESS_DIR="${PREPROCESS_DIR:-$ROOT/dist/preprocess}"
PREPROCESSED_ICON_PATH="${PREPROCESSED_ICON_PATH:-$PREPROCESS_DIR/${APP_NAME}.icns}"
PREPROCESSED_MIHOMO_PATH="${PREPROCESSED_MIHOMO_PATH:-$PREPROCESS_DIR/mihomo}"
REQUIRE_MIHOMO_BINARY="${REQUIRE_MIHOMO_BINARY:-1}"
BUNDLE_MIHOMO_BINARY="${BUNDLE_MIHOMO_BINARY:-1}"

APP="$ROOT/dist/${APP_NAME}.app"
cd "$ROOT"

BUILD_ARGS=(--product ClashBar -c release)
if [ "$RELEASE_OPTIMIZE_FOR_SIZE" = "1" ]; then
  BUILD_ARGS+=(-Xswiftc -Osize)
fi
if [ -n "$TARGET_ARCH" ]; then
  BUILD_ARGS+=(--arch "$TARGET_ARCH")
fi
swift build "${BUILD_ARGS[@]}"

if [ -n "$TARGET_ARCH" ]; then
  BIN_CANDIDATE="$ROOT/.build/${TARGET_ARCH}-apple-macosx/release/ClashBar"
  RESOURCE_BUNDLE_CANDIDATE="$ROOT/.build/${TARGET_ARCH}-apple-macosx/release/ClashBar_ClashBar.bundle"
  BIN_PATTERN="*/${TARGET_ARCH}-apple-macosx/release/ClashBar"
  RESOURCE_BUNDLE_PATTERN="*/${TARGET_ARCH}-apple-macosx/release/ClashBar_ClashBar.bundle"
else
  BIN_CANDIDATE="$ROOT/.build/release/ClashBar"
  RESOURCE_BUNDLE_CANDIDATE="$ROOT/.build/release/ClashBar_ClashBar.bundle"
  BIN_PATTERN="*/release/ClashBar"
  RESOURCE_BUNDLE_PATTERN="*/release/ClashBar_ClashBar.bundle"
fi

resolve_build_artifact() {
  local candidate="$1"
  local artifact_type="$2"
  local release_pattern="$3"

  if [ "$artifact_type" = "file" ] && [ -f "$candidate" ]; then
    echo "$candidate"
    return
  fi
  if [ "$artifact_type" = "dir" ] && [ -d "$candidate" ]; then
    echo "$candidate"
    return
  fi

  local find_type="f"
  if [ "$artifact_type" = "dir" ]; then
    find_type="d"
  fi
  find "$ROOT/.build" -path "$release_pattern" -type "$find_type" | head -n 1 || true
}

artifact_size_bytes() {
  stat -f%z "$1"
}

format_bytes() {
  local bytes="${1:-0}"
  awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ")
      size = bytes + 0
      unit_index = 1
      while (size >= 1024 && unit_index < 5) {
        size /= 1024
        unit_index++
      }
      if (unit_index == 1) {
        printf "%d %s", size, units[unit_index]
      } else {
        printf "%.1f %s", size, units[unit_index]
      }
    }
  '
}

print_artifact_size() {
  local label="$1"
  local path="$2"
  local bytes
  bytes="$(artifact_size_bytes "$path")"
  echo "$label: $(format_bytes "$bytes") ($bytes bytes)"
}

strip_binary_if_enabled() {
  local label="$1"
  local path="$2"

  if [ "$STRIP_BINARIES" != "1" ]; then
    print_artifact_size "$label (strip disabled)" "$path"
    return
  fi

  if ! command -v strip >/dev/null 2>&1; then
    echo "strip command not found while STRIP_BINARIES=1." >&2
    exit 1
  fi

  local before_bytes
  local after_bytes
  before_bytes="$(artifact_size_bytes "$path")"
  strip -S -x "$path"
  after_bytes="$(artifact_size_bytes "$path")"
  echo "$label stripped: $(format_bytes "$before_bytes") -> $(format_bytes "$after_bytes")"
}

mihomo_candidate_paths() {
  local filename="${1:-mihomo}"
  local bundle_dir="$APP/Contents/Resources/ClashBar_ClashBar.bundle"
  local resources_dir="$APP/Contents/Resources"

  printf '%s\n' \
    "$bundle_dir/$filename" \
    "$bundle_dir/bin/$filename" \
    "$bundle_dir/Resources/bin/$filename" \
    "$resources_dir/bin/$filename" \
    "$resources_dir/Resources/bin/$filename" \
    "$resources_dir/$filename"
}

resource_bundle_mihomo_candidate_paths() {
  local filename="${1:-mihomo}"

  printf '%s\n' \
    "$RESOURCE_BUNDLE/$filename" \
    "$RESOURCE_BUNDLE/bin/$filename" \
    "$RESOURCE_BUNDLE/Resources/bin/$filename"
}

resolve_existing_file_from_candidates() {
  local path=""

  while IFS= read -r path; do
    if [ -f "$path" ]; then
      echo "$path"
      return
    fi
  done
}

resolve_existing_mihomo_path() {
  local filename="${1:-mihomo}"

  mihomo_candidate_paths "$filename" | resolve_existing_file_from_candidates
}

resolve_existing_resource_bundle_mihomo_path() {
  local filename="${1:-mihomo}"

  resource_bundle_mihomo_candidate_paths "$filename" | resolve_existing_file_from_candidates
}

resolve_mihomo_install_path() {
  local filename="${1:-mihomo}"
  local path=""

  path="$(resolve_existing_mihomo_path "$filename")"
  if [ -n "$path" ]; then
    echo "$path"
    return
  fi

  while IFS= read -r path; do
    if [ -d "$(dirname "$path")" ]; then
      echo "$path"
      return
    fi
  done < <(mihomo_candidate_paths "$filename")

  echo "$APP/Contents/Resources/ClashBar_ClashBar.bundle/$filename"
}
remove_bundled_mihomo_candidates() {
  local filename="$1"
  local path=""

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -f "$path" ]; then
      rm -f "$path"
    fi
  done < <(printf '%s\n' \
    "$(resolve_mihomo_install_path "$filename")" \
    "$APP/Contents/Resources/ClashBar_ClashBar.bundle/bin/$filename" \
    "$APP/Contents/Resources/ClashBar_ClashBar.bundle/Resources/bin/$filename" \
    "$APP/Contents/Resources/bin/$filename" \
    "$APP/Contents/Resources/Resources/bin/$filename" \
    "$APP/Contents/Resources/$filename" | awk '!seen[$0]++')
}

BIN="$(resolve_build_artifact "$BIN_CANDIDATE" file "$BIN_PATTERN")"
RESOURCE_BUNDLE="$(resolve_build_artifact "$RESOURCE_BUNDLE_CANDIDATE" dir "$RESOURCE_BUNDLE_PATTERN")"

if [ ! -f "$BIN" ]; then
  echo "Build output not found: $BIN" >&2
  exit 1
fi
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "Resource bundle not found: $RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ClashBar"
chmod +x "$APP/Contents/MacOS/ClashBar"

rm -rf "$APP/Contents/Resources/ClashBar_ClashBar.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/ClashBar_ClashBar.bundle"

if [ "$BUNDLE_MIHOMO_BINARY" = "1" ]; then
  if [ -f "$PREPROCESSED_MIHOMO_PATH" ]; then
    MIHOMO_SOURCE_PATH="$PREPROCESSED_MIHOMO_PATH"
  else
    MIHOMO_SOURCE_PATH="$(resolve_existing_resource_bundle_mihomo_path "mihomo")"
  fi

  if [ -n "$MIHOMO_SOURCE_PATH" ]; then
    MIHOMO_INSTALL_PATH="$(resolve_mihomo_install_path "mihomo.gz")"
    mkdir -p "$(dirname "$MIHOMO_INSTALL_PATH")"
    remove_bundled_mihomo_candidates "mihomo"
    remove_bundled_mihomo_candidates "mihomo.gz"
    gzip -c "$MIHOMO_SOURCE_PATH" > "$MIHOMO_INSTALL_PATH"
    chmod 644 "$MIHOMO_INSTALL_PATH"
    echo "Bundled compressed mihomo payload: $MIHOMO_INSTALL_PATH"
  elif [ "$REQUIRE_MIHOMO_BINARY" = "1" ]; then
    echo "Missing preprocessed mihomo binary: $PREPROCESSED_MIHOMO_PATH" >&2
    echo "Run ./Scripts/preprocess.sh (or ./Scripts/build.sh app/all) before packaging." >&2
    exit 1
  else
    echo "Warning: preprocessed mihomo binary not found, and no bundled mihomo resource was available."
  fi
else
  remove_bundled_mihomo_candidates "mihomo"
  remove_bundled_mihomo_candidates "mihomo.gz"
  echo "Skipped bundling mihomo payload."
fi

print_artifact_size "Main binary before strip" "$APP/Contents/MacOS/ClashBar"
strip_binary_if_enabled "Main binary" "$APP/Contents/MacOS/ClashBar"

ICON_PLIST_ENTRY=""
if [ -f "$PREPROCESSED_ICON_PATH" ]; then
  cp "$PREPROCESSED_ICON_PATH" "$APP/Contents/Resources/${APP_NAME}.icns"
  ICON_PLIST_ENTRY="<key>CFBundleIconFile</key><string>${APP_NAME}.icns</string>"
else
  echo "Warning: preprocessed icon not found at $PREPROCESSED_ICON_PATH"
fi

if [ "$BUNDLE_MIHOMO_BINARY" = "1" ]; then
  BUNDLES_MIHOMO_CORE_PLIST_VALUE="<true/>"
else
  BUNDLES_MIHOMO_CORE_PLIST_VALUE="<false/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundleExecutable</key><string>ClashBar</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
$ICON_PLIST_ENTRY
<key>ClashBarBundlesMihomoCore</key>${BUNDLES_MIHOMO_CORE_PLIST_VALUE}
<key>NSLocationWhenInUseUsageDescription</key><string>ClashBar uses your current Wi-Fi name to switch proxy config profiles automatically.</string>
<key>NSAppTransportSecurity</key>
<dict>
<key>NSAllowsArbitraryLoads</key><true/>
</dict>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "Built app: $APP"
du -sh "$APP"
