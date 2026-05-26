#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RufusX"
PROJECT="RufusX.xcodeproj"
SCHEME="RufusX"
CONFIGURATION="Release"
TEAM_ID="${DEVELOPMENT_TEAM:-33832Z66QU}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: doeshing Chen (33832Z66QU)}"
BUILD_DIR="${BUILD_DIR:-build/package}"
DIST_DIR="${DIST_DIR:-dist}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/RufusXPackageDerivedData}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
UNSIGNED=0
NOTARIZE=0
CLEAN=1

usage() {
  cat <<'USAGE'
Usage: scripts/package_dmg.sh [options]

Builds RufusX.app, creates a DMG, signs it with Developer ID by default, and
optionally submits the DMG for notarization.

Options:
  --unsigned                     Build without Developer ID signing.
  --sign-identity <identity>      Developer ID Application identity to use.
  --team-id <team-id>             Apple Developer Team ID.
  --configuration <name>          Xcode configuration. Default: Release.
  --build-dir <path>              Build/package working directory.
  --output-dir <path>             DMG output directory.
  --derived-data <path>           Xcode derived data path.
  --notarize                     Submit the DMG to Apple notarization.
  --notary-profile <profile>      notarytool keychain profile name.
  --no-clean                     Do not clean package working directories first.
  -h, --help                     Show this help.

Notarization can use either:
  NOTARY_PROFILE / --notary-profile
or App Store Connect API key environment variables:
  APPLE_NOTARY_KEY_PATH, APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER_ID
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned)
      UNSIGNED=1
      shift
      ;;
    --sign-identity)
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --output-dir)
      DIST_DIR="$2"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --no-clean)
      CLEAN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
STAGING_DIR="$BUILD_DIR/dmg-root"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

if [[ "$UNSIGNED" -eq 1 && "$NOTARIZE" -eq 1 ]]; then
  echo "Cannot notarize an unsigned build." >&2
  exit 64
fi

if [[ "$UNSIGNED" -eq 0 ]]; then
  if ! security find-identity -p codesigning -v | grep -Fq "$SIGN_IDENTITY"; then
    echo "Signing identity not found: $SIGN_IDENTITY" >&2
    echo "Available identities:" >&2
    security find-identity -p codesigning -v >&2 || true
    exit 65
  fi
fi

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR" "$DIST_DIR"

build_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  archive
  SKIP_INSTALL=NO
  ENABLE_HARDENED_RUNTIME=YES
)

if [[ "$UNSIGNED" -eq 1 ]]; then
  build_args+=(CODE_SIGNING_ALLOWED=NO)
else
  build_args+=(
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
fi

echo "Building archive..."
xcodebuild "${build_args[@]}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive did not produce $APP_PATH" >&2
  exit 66
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1")"
STAMP="$(date -u +%Y%m%d%H%M%S)"
DMG_NAME="$APP_NAME-$VERSION-$BUILD_NUMBER-$STAMP.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if [[ "$UNSIGNED" -eq 0 ]]; then
  echo "Signing nested executables and app bundle..."
  while IFS= read -r -d '' nested_executable; do
    if [[ "$nested_executable" != "$APP_PATH/Contents/MacOS/$APP_NAME" ]]; then
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested_executable"
    fi
  done < <(find "$APP_PATH/Contents" -type f -perm -111 -print0)

  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG: $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

if [[ "$UNSIGNED" -eq 0 ]]; then
  echo "Signing DMG..."
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [[ "$NOTARIZE" -eq 1 ]]; then
  notary_args=()
  if [[ -n "$NOTARY_PROFILE" ]]; then
    notary_args+=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${APPLE_NOTARY_KEY_PATH:-}" && -n "${APPLE_NOTARY_KEY_ID:-}" && -n "${APPLE_NOTARY_ISSUER_ID:-}" ]]; then
    notary_args+=(
      --key "$APPLE_NOTARY_KEY_PATH"
      --key-id "$APPLE_NOTARY_KEY_ID"
      --issuer "$APPLE_NOTARY_ISSUER_ID"
    )
  else
    echo "Notarization requested, but no notary credentials were provided." >&2
    exit 67
  fi

  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" "${notary_args[@]}" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Package complete: $DMG_PATH"
