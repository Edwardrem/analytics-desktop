import Foundation
import CryptoKit

/// Ed25519 signatures over update archives. Releases are only ad-hoc code signed (there is no Apple
/// Developer ID), so this check is what proves an update came from the owner: `Scripts/sign-update.swift`
/// signs each zip's bytes with the private key, and the app checks them against the public key that
/// `Scripts/make-update-key.sh` wrote to `Resources/UpdatePublicKey.txt` (copied into the bundle).
///
/// Both files are base64 text: the key is the 32-byte raw public key, the `.sig` the 64-byte signature.
enum UpdateSignature {
    static let keyResource = "UpdatePublicKey"

    /// The public key embedded in the running app, or a clear error when this build has none.
    static func bundledKey(_ bundle: Bundle = .main) throws -> Curve25519.Signing.PublicKey {
        guard let url = bundle.url(forResource: keyResource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw UpdateError.signature("This copy of the app was built without an update signing key, so it can't check that an update is genuine. Download the new version from GitHub instead.")
        }
        return try publicKey(text)
    }

    static func publicKey(_ text: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = decode(text), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateError.signature("The app's update signing key is damaged, so updates can't be checked.")
        }
        return key
    }

    /// Throws unless `signatureText` is a valid signature of exactly `data` by `key`.
    static func verify(_ data: Data, signatureText: String, key: Curve25519.Signing.PublicKey) throws {
        guard let signature = decode(signatureText), signature.count == 64 else {
            throw UpdateError.signature("The update's signature is malformed, so the update was refused.")
        }
        guard key.isValidSignature(signature, for: data) else {
            throw UpdateError.signature("The update's signature doesn't match: the download may be damaged or not from the app's publisher, so it was refused and deleted.")
        }
    }

    /// Verifies a file on disk (read without copying when the file system allows).
    static func verify(file: URL, signatureText: String, key: Curve25519.Signing.PublicKey) throws {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            throw UpdateError.signature("The downloaded update couldn't be read to check its signature.")
        }
        try verify(data, signatureText: signatureText, key: key)
    }

    /// Strict base64 of one line (surrounding whitespace allowed).
    private static func decode(_ text: String) -> Data? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        return Data(base64Encoded: t)
    }
}
