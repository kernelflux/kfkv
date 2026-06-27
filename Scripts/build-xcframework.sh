#!/bin/bash
# Scripts/build-xcframework.sh
# Build KFKV XCFramework for binary distribution
#
# Usage: ./Scripts/build-xcframework.sh [version]
# Example: ./Scripts/build-xcframework.sh 1.0.0
#
# Prerequisite: Xcode 16+ with iOS 18+ simulator runtime
# Output: Frameworks/KFKV.xcframework.zip + checksum

set -euo pipefail

VERSION="${1:-0.0.0}"
SCHEME="KFKV"
BUILD_DIR=".build/xcframework"
OUTPUT_DIR="Frameworks"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
err()  { echo -e "${RED}==>${NC} $*" >&2; }

# ── Build archive for a single platform ──
archive() {
    local sdk="$1" dest="$2" label="$3"
    log "Archiving for ${label} (${sdk})..."
    xcodebuild archive \
        -scheme "${SCHEME}" \
        -destination "${dest}" \
        -archivePath "${BUILD_DIR}/${label}.xcarchive" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        OTHER_SWIFT_FLAGS="-no-verify-emitted-module-interface" \
        2>&1 | grep -E "(error:|warning:|ARCHIVE|FAILED)" || true
}

# ── Create framework bundle from .o files ──
assemble_framework() {
    local archive="$1" output="$2"
    local product_dir="${archive}/Products"

    log "Assembling framework from ${archive}..."

    # Find all .o files
    local objects
    objects=$(find "${product_dir}" -name "*.o" -print0 | xargs -0)

    if [ -z "${objects}" ]; then
        err "No .o files found in ${product_dir}"
        return 1
    fi

    rm -rf "${output}"
    mkdir -p "${output}/Headers" "${output}/Modules"

    # Link all .o files into a static library
    local lib_path="${output}/KFKV"
    ar crs "${lib_path}" ${objects}

    # Copy public headers from the package source
    cp Sources/KFKV/KFKV.h "${output}/Headers/"
    cp Sources/KFKV/KFKVHandler.h "${output}/Headers/"

    # Create module map
    cat > "${output}/Modules/module.modulemap" << MODULEMAP
framework module KFKV {
    umbrella header "KFKV.h"
    export *
    module * { export * }
}
MODULEMAP

    # Create Info.plist
    cat > "${output}/Info.plist" << INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>KFKV</string>
    <key>CFBundleIdentifier</key>
    <string>com.kernelflux.kfkv</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
</dict>
</plist>
INFOPLIST

    log "Framework assembled: ${output}"
}

# ── Main ──
log "Building KFKV XCFramework v${VERSION}..."

rm -rf "${BUILD_DIR}" "${OUTPUT_DIR}"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

archive "iphoneos"       "generic/platform=iOS"           "ios"
archive "iphonesimulator" "generic/platform=iOS Simulator"  "ios-sim"

assemble_framework "${BUILD_DIR}/ios.xcarchive"      "${BUILD_DIR}/ios/KFKV.framework"
assemble_framework "${BUILD_DIR}/ios-sim.xcarchive"  "${BUILD_DIR}/ios-sim/KFKV.framework"

log "Creating XCFramework..."
xcodebuild -create-xcframework \
    -framework "${BUILD_DIR}/ios/KFKV.framework" \
    -framework "${BUILD_DIR}/ios-sim/KFKV.framework" \
    -output "${OUTPUT_DIR}/KFKV.xcframework"

log "Packaging..."
cd "${OUTPUT_DIR}"
zip -r -q "KFKV.xcframework.zip" "KFKV.xcframework"
CHECKSUM=$(swift package compute-checksum "KFKV.xcframework.zip")
cd ..

echo ""
echo "----------------------------------------"
echo "  XCFramework built successfully"
echo "  Version:  ${VERSION}"
echo "  Output:   ${OUTPUT_DIR}/KFKV.xcframework"
echo "  Zip:      ${OUTPUT_DIR}/KFKV.xcframework.zip"
echo "  Checksum: ${CHECKSUM}"
echo "----------------------------------------"
echo ""
echo "  Next: create a GitHub Release with the zip"
echo "    gh release create v${VERSION} ${OUTPUT_DIR}/KFKV.xcframework.zip"
