#!/bin/bash
# Builds Yaga.app into dist/ and (optionally) installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="dist/Yaga.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Yaga

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Yaga"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# A stable identity keeps the Keychain from re-prompting on every rebuild:
# access control is bound to the signature, and ad-hoc signing produces a new
# one each time. SIGN_IDENTITY can be a self-signed code-signing certificate
# (Keychain Access > Certificate Assistant) or a real Developer ID.
# Match by SHA-1 rather than name: a self-signed cert is untrusted (which
# codesign accepts fine) and duplicates of the same name are ambiguous.
IDENTITY=${SIGN_IDENTITY:-}
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Yaga Dev"/ {print $2; exit}')
fi

if [ -n "$IDENTITY" ]; then
  echo "==> Signing as ${SIGN_IDENTITY:-Yaga Dev} ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "==> Signing (ad-hoc; expect Keychain prompts on each rebuild)"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
    echo "    (ad-hoc signing failed; the app will still run)"
fi

echo "==> Built $APP"

if [ "${1:-}" = "--dist" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  ZIP="dist/Yaga-$VERSION-arm64.zip"
  rm -f "$ZIP"
  # ditto preserves the signature and resource forks; `zip` does not.
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
  echo "==> Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
  cat <<'NOTE'

    Apple silicon only, signed ad-hoc — Gatekeeper will not recognise it.

    Transfer with scp or a USB drive if you can: those do not set the
    quarantine flag, so the app opens normally. AirDrop, email and browser
    downloads do set it, and then macOS refuses the app outright.

    To clear quarantine on the target machine:

        unzip Yaga-*-arm64.zip -d /Applications
        xattr -dr com.apple.quarantine /Applications/Yaga.app
        open /Applications/Yaga.app

    Without that command: System Settings > Privacy & Security, scroll to
    "Yaga was blocked", click Open Anyway. Control-click > Open no longer
    works on current macOS.

NOTE
  exit 0
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x Yaga || true
  rm -rf /Applications/Yaga.app
  cp -R "$APP" /Applications/Yaga.app
  echo "==> Installed to /Applications/Yaga.app"
  open /Applications/Yaga.app
fi
