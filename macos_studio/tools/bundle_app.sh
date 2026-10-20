#!/bin/bash
# bundle_app.sh — build release binaries and assemble ChronoForgeStudio.app
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(dirname "$HERE")"
cd "$PKG"

APP="$PKG/build/ChronoForgeStudio.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
FW="$CONTENTS/Frameworks"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"
echo "==> bin path: $BIN"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES" "$FW"

echo "==> copying binaries"
cp "$BIN/ChronoForgeStudioApp" "$MACOS/ChronoForgeStudio"
cp "$BIN/chronoforge" "$MACOS/chronoforge"
cp -R "$PKG/ThirdParty" "$RES/Licenses"

echo "==> Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>ChronoForge Studio</string>
    <key>CFBundleDisplayName</key>       <string>ChronoForge Studio</string>
    <key>CFBundleExecutable</key>        <string>ChronoForgeStudio</string>
    <key>CFBundleIdentifier</key>        <string>com.chronoforge.studio</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> PkgInfo"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---- libctcodec.dylib: bundle + fixup if present -------------------------
DYLIB="$PKG/../re_workspace/tools/libctcodec/libctcodec.dylib"
if [[ -f "$DYLIB" ]]; then
    echo "==> bundling libctcodec.dylib"
    cp "$DYLIB" "$FW/libctcodec.dylib"
    chmod u+w "$FW/libctcodec.dylib"
    CUR="$(otool -D "$FW/libctcodec.dylib" | tail -1)"
    if [[ "$CUR" != "@executable_path/../Frameworks/libctcodec.dylib" ]]; then
        install_name_tool -id "@executable_path/../Frameworks/libctcodec.dylib" \
            "$FW/libctcodec.dylib"
    fi
    # The Swift side dlopen()s by @executable_path/../Frameworks path at
    # runtime; nothing to rewrite in the executables themselves.
else
    echo "==> libctcodec.dylib not found — app will use the Swift fallback"
fi

echo "==> ad-hoc codesign"
if [[ -f "$FW/libctcodec.dylib" ]]; then
    codesign --force --sign - "$FW/libctcodec.dylib"
fi
codesign --force --sign - "$MACOS/chronoforge"
codesign --force --sign - "$MACOS/ChronoForgeStudio"
codesign --force --sign - "$APP"

echo "==> verify"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
echo "    --- otool -L ChronoForgeStudio ---"
otool -L "$MACOS/ChronoForgeStudio" | sed 's/^/    /'
if [[ -f "$FW/libctcodec.dylib" ]]; then
    echo "    --- otool -D libctcodec.dylib ---"
    otool -D "$FW/libctcodec.dylib" | sed 's/^/    /'
fi

echo "==> bundle ready: $APP"
