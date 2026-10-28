#!/bin/bash
# Builds Saturday.app into mac/build/. Pass --install to copy it to /Applications as well.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Saturday"
APP="build/Saturday.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Saturday"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable local certificate instead of an ad-hoc signature. macOS ties permissions
# (Accessibility, Screen Recording, Automation…) to the signature, so with the same certificate
# every rebuild keeps the permissions you already granted.
IDENTITY="Saturday Local Signing"
KEYCHAIN="$HOME/Library/Keychains/saturday-signing.keychain-db"
KEYCHAIN_PASSWORD="saturday-local"

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "Creating the local signing certificate (one time)…"
    WORK="$(mktemp -d)"
    cat > "$WORK/cert.cfg" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cfg" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    LEGACY=""
    openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY="-legacy"
    openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$IDENTITY" -out "$WORK/identity.p12" -passout pass:"$KEYCHAIN_PASSWORD"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    rm -rf "$WORK"
fi

# codesign only finds identities in keychains on the search list; add ours, keeping the others.
if ! security list-keychains -d user | grep -q "saturday-signing"; then
    KEYCHAINS=()
    while IFS= read -r line; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
        [[ -n "$line" ]] && KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${KEYCHAINS[@]}" "$KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

if codesign --force --sign "$IDENTITY" --identifier com.saturday.assistant "$APP" 2>/dev/null; then
    echo "Signed with \"$IDENTITY\" (permissions survive rebuilds)"
else
    echo "warning: local certificate unavailable, signing ad hoc (permissions may reset after rebuilds)"
    codesign --force --sign - "$APP"
fi

echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Saturday.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Saturday.app"
fi
