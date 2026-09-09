#!/bin/zsh
# Build the Reprompt executable with SwiftPM and assemble dist/Reprompt.app.
#
# Signing: the Accessibility (TCC) grant is keyed on the bundle id plus the code-signing
# requirement. Ad-hoc signing (-s -) yields a per-build cdhash requirement, so the grant
# would silently stop matching after every rebuild. We sign with a stable identity instead:
# REPROMPT_SIGN_IDENTITY, else the first "Apple Development" identity in the keychain,
# else a self-signed "Reprompt Dev" certificate (create one with scripts/make-signing-cert.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Reprompt

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Reprompt"
APP="dist/Reprompt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reprompt"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp assets/Reprompt.icns "$APP/Contents/Resources/Reprompt.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

IDENTITY="${REPROMPT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Reprompt Dev"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No stable signing identity found. Run scripts/make-signing-cert.sh or set REPROMPT_SIGN_IDENTITY." >&2
  echo "Falling back to ad-hoc signing: Accessibility permission will need re-granting after each rebuild." >&2
  IDENTITY="-"
fi

codesign --force --sign "$IDENTITY" --identifier com.holdenrichard.reprompt --timestamp=none "$APP"
echo "Built $APP (signed with: $IDENTITY)"
codesign -d -r- "$APP" 2>&1 | grep -E "^designated" || true
