#!/bin/sh
set -eu
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
fi

APP=build/CO2Bar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" Sources/*.swift -o "$APP/Contents/MacOS/CO2Bar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

if [ "${1:-}" = "install" ]; then
    mkdir -p "$HOME/Applications"
    pkill -x CO2Bar || true
    rm -rf "$HOME/Applications/CO2Bar.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/CO2Bar.app"
    echo "Installed to ~/Applications/CO2Bar.app"
fi
