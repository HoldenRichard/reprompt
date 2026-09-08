#!/bin/zsh
# One-time: create a self-signed code-signing certificate named "Reprompt Dev" in the login
# keychain, for machines without an Apple Development identity. Interactive: opens
# Keychain Access' Certificate Assistant because `security` cannot create code-signing
# certs non-interactively.
set -euo pipefail
if security find-identity -v -p codesigning | grep -q '"Reprompt Dev"'; then
  echo "Reprompt Dev identity already exists."; exit 0
fi
cat <<'MSG'
Create the certificate in Keychain Access:
  1. Keychain Access > Certificate Assistant > Create a Certificate...
  2. Name: Reprompt Dev   Identity Type: Self Signed Root   Certificate Type: Code Signing
  3. Create, then in the login keychain double-click the cert > Trust > Code Signing: Always Trust
Then re-run scripts/bundle.sh.
MSG
open -a "Keychain Access"
