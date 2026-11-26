#!/bin/bash
# Builds "Usage Pill.app" and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Usage Pill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Work around a Command Line Tools bug ("redefinition of module 'SwiftBridging'")
# by hiding the duplicate modulemap from the compiler. No system files are changed.
EXTRA=()
DUPDIR=/Library/Developer/CommandLineTools/usr/include/swift
if [ -f "$DUPDIR/bridging.modulemap" ] && [ -f "$DUPDIR/module.modulemap" ]; then
  : > build/empty.modulemap
  cat > build/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "directory", "name": "$DUPDIR",
    "contents": [ { "type": "file", "name": "bridging.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
YAML
  EXTRA=(-vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml)
fi

swiftc -O -swift-version 5 ${EXTRA[@]+"${EXTRA[@]}"} -o "$APP/Contents/MacOS/UsagePill" main.swift \
  -framework AppKit -framework SwiftUI -framework Network -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

mkdir -p ~/Applications
pkill -x UsagePill 2>/dev/null || true
rm -rf ~/Applications/"Usage Pill.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Usage Pill.app"
