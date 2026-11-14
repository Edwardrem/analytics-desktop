#!/bin/sh
# Makes the Ed25519 key pair that signs Analytics Desktop updates. Run once, by the owner, on their own Mac.
#
#   Scripts/make-update-key.sh [--force]
#
# - Writes the public key to Resources/UpdatePublicKey.txt (commit it: every build embeds it, and the app
#   refuses any update whose signature doesn't match it).
# - Stores the private key in your login Keychain (service below, account "update-signing"). It is never
#   printed or written to a file; the Swift snippet hands it straight to the Keychain.
# - Prints the `gh secret set` command that copies it from the Keychain into the repository's
#   UPDATE_SIGNING_KEY secret for the release workflow.
#
# Replacing the key (--force) strands every installed copy: they keep the old public key and will refuse
# updates signed with the new one, so their users have to download the next version by hand.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PUBLIC="$ROOT/Resources/UpdatePublicKey.txt"
SERVICE="io.github.edwardrem.AnalyticsDesktop.update-signing"
ACCOUNT="update-signing"
REPO="Edwardrem/analytics-desktop"

if [ -f "$PUBLIC" ] && [ "${1:-}" != "--force" ]; then
    echo "Resources/UpdatePublicKey.txt already exists. Installed copies trust that key; replacing it means they" >&2
    echo "can no longer update themselves. Re-run with --force only if you mean to replace it." >&2
    exit 1
fi

SNIPPET="$(mktemp -d)/make-update-key.swift"
cat > "$SNIPPET" <<'SWIFT'
import CryptoKit
import Foundation
import Security

let service = CommandLine.arguments[1], account = CommandLine.arguments[2]
let key = Curve25519.Signing.PrivateKey()
let secret = Data(key.rawRepresentation.base64EncodedString().utf8)
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service, kSecAttrAccount as String: account]
SecItemDelete(query as CFDictionary)
var add = query
add[kSecValueData as String] = secret
add[kSecAttrLabel as String] = "Analytics Desktop update signing key"
let status = SecItemAdd(add as CFDictionary, nil)
guard status == errSecSuccess else {
    FileHandle.standardError.write(Data("Couldn't store the private key in the Keychain (OSStatus \(status)).\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT

PUB="$(swift "$SNIPPET" "$SERVICE" "$ACCOUNT")"
rm -rf "$(dirname "$SNIPPET")"
printf '%s\n' "$PUB" > "$PUBLIC"

echo "✓ Public key written to Resources/UpdatePublicKey.txt — commit it."
echo "✓ Private key stored in your login Keychain (service $SERVICE)."
echo
echo "Now copy the private key into the repository secret (macOS may ask to let 'security' read the item):"
echo
echo "    security find-generic-password -s '$SERVICE' -a '$ACCOUNT' -w | gh secret set UPDATE_SIGNING_KEY --repo $REPO"
echo
echo "To sign a release locally:  UPDATE_SIGNING_KEY=\"\$(security find-generic-password -s '$SERVICE' -a '$ACCOUNT' -w)\" Scripts/release.sh 0.9.0"
