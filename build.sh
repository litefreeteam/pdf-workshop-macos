#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"
BUILD_DIR="${BUILD_WORK_DIR:-$PROJECT_DIR/.build/package}"
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP="$OUTPUT_DIR/PDF 工坊.app"
cd "$PROJECT_DIR"
BINARIES=()
for ARCH in ${ARCHS:-arm64 x86_64}; do
    swift build -c release --triple "$ARCH-apple-macosx13.0" --product PDFWorkshop --scratch-path "$BUILD_DIR/$ARCH"
    BIN_DIR="$(swift build -c release --triple "$ARCH-apple-macosx13.0" --scratch-path "$BUILD_DIR/$ARCH" --show-bin-path)"
    BINARIES+=("$BIN_DIR/PDFWorkshop")
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINARIES[@]}" -eq 1 ]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/PDFWorkshop"
else
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/PDFWorkshop"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift Resources/MakeIcon.swift "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/PDFWorkshop-macOS.zip"
cd "$OUTPUT_DIR"
shasum -a 256 PDFWorkshop-macOS.zip > SHA256SUMS.txt
echo "Built: $APP"
