#!/usr/bin/env bash
# Creates a self-signed code-signing certificate for Vignette.
#
# This does NOT satisfy Gatekeeper — only Apple notarization does, and that needs
# a paid membership. What it buys is a *stable* signature: ad-hoc signing produces
# a different hash on every build, which silently revokes the app's Accessibility
# grant on every update. Signing with one persistent certificate keeps the grant.
#
# Run locally. The private key never needs to leave your machine except as the
# encrypted .p12 you paste into GitHub secrets.

set -euo pipefail

NAME="Vignette Self-Signed"
OUT="${TMPDIR:-/tmp}/vignette-signing"
mkdir -p "$OUT"
cd "$OUT"

read -rsp "Choose a password to encrypt the .p12 (you'll paste it into GitHub secrets): " P12_PASS
echo

echo "==> Generating key and certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=$NAME/O=Vignette/C=SE" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

echo "==> Bundling into a .p12"
openssl pkcs12 -export -inkey key.pem -in cert.pem -out signing.p12 \
  -name "$NAME" -passout pass:"$P12_PASS"

echo "==> Importing into your login keychain (for local release builds)"
security import signing.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "$P12_PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || \
  echo "    (if codesign prompts for your password later, run set-key-partition-list manually)"

echo "==> Trusting it for code signing (needs admin)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain cert.pem

echo
echo "Done. Certificate name: $NAME"
echo
echo "Add these to the repo's GitHub secrets:"
echo "  SIGNING_CERT_P12       = (contents of the base64 file below)"
echo "  SIGNING_CERT_PASSWORD  = (the password you just chose)"
echo "  KEYCHAIN_PASSWORD      = (any random string; CI uses it for a temp keychain)"
echo
base64 -i signing.p12 -o signing.p12.base64
echo "Base64 of the .p12 written to: $OUT/signing.p12.base64"
echo
echo "Copy it with:  pbcopy < $OUT/signing.p12.base64"
echo "Then delete the directory:  rm -rf $OUT"
