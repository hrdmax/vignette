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
umask 077

NAME="Vignette Self-Signed"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/vignette-signing.XXXXXX")"
cleanup() {
  rm -f -- "$OUT/key.pem" "$OUT/cert.pem" "$OUT/signing.p12" "$OUT/signing.p12.base64"
  rmdir -- "$OUT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$OUT"

read -rsp "Choose a password to encrypt the .p12 (you'll paste it into GitHub secrets): " P12_PASS
echo
if [ -z "$P12_PASS" ]; then
  echo "A nonempty password is required." >&2
  exit 1
fi
export P12_PASS

echo "==> Generating key and certificate"
openssl req -x509 -newkey rsa:2048 -passout env:P12_PASS -days 3650 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=$NAME/O=Vignette/C=SE" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

echo "==> Bundling into a .p12"
# The legacy algorithms are not optional. OpenSSL 3 defaults to AES-256 with a
# SHA-256 MAC, which macOS's `security import` cannot read — and it reports the
# failure as "MAC verification failed (wrong password?)", which sends you hunting
# for a credential problem that isn't there.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out signing.p12 \
  -name "$NAME" -passin env:P12_PASS -passout env:P12_PASS \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "==> Importing into your login keychain (for local release builds)"
security import signing.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "$P12_PASS" -T /usr/bin/codesign
unset P12_PASS
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
echo "Temporary signing files are deleted when this script exits."
read -rp "Press Return after saving the GitHub secrets to delete the temporary files. "
