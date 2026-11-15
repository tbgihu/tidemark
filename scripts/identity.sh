#!/bin/zsh
# Creates Tidemark's signing identity once: a self-signed code-signing certificate in a keychain of its own
# (~/Library/Application Support/Tidemark/signing), never in your login keychain. build.sh signs Tidemark.app with it.
#
# macOS ties what you allow an app to how it is signed: notifications and the login item name the certificate and
# survive rebuilds and updates; ad-hoc signing ties them to a single build. (Keychain items don't depend on it:
# Tidemark keeps them through /usr/bin/security, so no build ever asks for them.) The keychain is separate because
# the scripts know its password and grant codesign the key once (the partition list), so there is never a "codesign
# wants to use" prompt. It is not in your search list, so Keychain Access doesn't show it. `make uninstall` removes it.
#
# Skipped when SIGN_ID names another identity.
set -euo pipefail
source "${0:A:h}/lib.sh"

[[ -n ${SIGN_ID-} ]] && exit 0
if [[ -f $signing/password ]] && security find-certificate -c "$identity" $keychain >/dev/null 2>&1; then
  exit 0
fi

print "  creating  signing certificate"
umask 077
mkdir -p $signing
rm -f $keychain
password=$(/usr/bin/openssl rand -hex 24)
print -r -- $password > $signing/password

searchlist=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
security create-keychain -p $password $keychain
security list-keychains -d user -s $searchlist                  # keep it out of the search list
security set-keychain-settings $keychain                        # no auto-lock
security unlock-keychain -p $password $keychain

tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$identity" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name "$identity" \
  -passout pass:tidemark -out $tmp/identity.p12
security import $tmp/identity.p12 -k $keychain -P tidemark -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $password $keychain >/dev/null
