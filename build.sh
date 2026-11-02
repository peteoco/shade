#!/bin/bash
set -e; cd "$(dirname "$0")"
A=Blackout.app; rm -rf $A; mkdir -p $A/Contents/MacOS
swiftc -O main.swift -o $A/Contents/MacOS/Blackout -framework Cocoa
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleName</key><string>Blackout</string><key>CFBundleIdentifier</key><string>com.peteoconnell.blackout</string>
<key>CFBundleExecutable</key><string>Blackout</string><key>CFBundleVersion</key><string>2</string><key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
P
mkdir -p $A/Contents/Resources; cp AppIcon.icns $A/Contents/Resources/
codesign --force -s - $A
