#!/bin/sh
set -eu
cd "$(dirname "$0")"

usage() {
    echo "Usage: $0 [install [<honeycomb-board-url>]]" >&2
    exit 1
}

BOARD_URL="${2:-}"
case "${1:-}" in
    "" | install) ;;
    *) usage ;;
esac
case "$BOARD_URL" in
    "" | https://ui.*honeycomb.io/*/environments/*/board/*) ;;
    *) echo "Not a Honeycomb board URL: $BOARD_URL" >&2; usage ;;
esac

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
    while pgrep -x CO2Bar >/dev/null; do sleep 0.2; done
    rm -rf "$HOME/Applications/CO2Bar.app"
    cp -R "$APP" "$HOME/Applications/"
    if [ -n "$BOARD_URL" ]; then
        open "$HOME/Applications/CO2Bar.app" --args --board "$BOARD_URL"
    else
        open "$HOME/Applications/CO2Bar.app"
    fi
    echo "Installed to ~/Applications/CO2Bar.app"
fi
