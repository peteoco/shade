#!/bin/bash
set -e; cd "$(dirname "$0")"
A=Shade.app; rm -rf $A; mkdir -p $A/Contents/MacOS
# Universal binary (Apple silicon + Intel), runs on macOS 13 and later
for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos13 *.swift -o /tmp/Shade-$arch -framework Cocoa -framework SwiftUI; done
lipo -create /tmp/Shade-arm64 /tmp/Shade-x86_64 -output $A/Contents/MacOS/Shade
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleName</key><string>Shade</string><key>CFBundleIdentifier</key><string>com.peteoconnell.shade</string>
<key>CFBundleExecutable</key><string>Shade</string><key>CFBundleVersion</key><string>6</string><key>CFBundleShortVersionString</key><string>2.1</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
P
mkdir -p $A/Contents/Resources; cp AppIcon.icns $A/Contents/Resources/
codesign --force -s - $A
