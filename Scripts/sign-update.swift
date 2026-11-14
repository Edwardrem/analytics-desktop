// Signs and checks Analytics Desktop update archives with Ed25519 (CryptoKit).
//
//   swift Scripts/sign-update.swift sign ZIP > ZIP.sig
//       Signs the zip's bytes with the private key in $UPDATE_SIGNING_KEY (base64 of the 32-byte raw key,
//       as Scripts/make-update-key.sh stores it) and prints the base64 signature.
//   swift Scripts/sign-update.swift verify PUBLIC_KEY_FILE ZIP SIG_FILE
//       Exits 0 only when SIG_FILE is a valid signature of ZIP by the key in PUBLIC_KEY_FILE
//       (Resources/UpdatePublicKey.txt). Scripts/release.sh runs this so a release signed with the wrong
//       key never ships.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

func base64(_ text: String, what: String) -> Data {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, let d = Data(base64Encoded: t) else { fail("\(what) isn't base64.") }
    return d
}

func read(_ path: String) -> Data {
    guard let d = FileManager.default.contents(atPath: path) else { fail("can't read \(path).") }
    return d
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "sign" where args.count == 2:
    guard let secret = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"], !secret.isEmpty else {
        fail("UPDATE_SIGNING_KEY is not set.")
    }
    let raw = base64(secret, what: "UPDATE_SIGNING_KEY")
    guard raw.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("UPDATE_SIGNING_KEY is not a 32-byte Ed25519 private key.")
    }
    let zip = read(args[1])
    guard let signature = try? key.signature(for: zip) else { fail("signing failed.") }
    print(signature.base64EncodedString())

case "verify" where args.count == 4:
    let rawKey = base64(String(decoding: read(args[1]), as: UTF8.self), what: args[1])
    guard rawKey.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
        fail("\(args[1]) is not a 32-byte Ed25519 public key.")
    }
    let signature = base64(String(decoding: read(args[3]), as: UTF8.self), what: args[3])
    guard signature.count == 64, key.isValidSignature(signature, for: read(args[2])) else {
        fail("the signature in \(args[3]) does not match \(args[2]) and \(args[1]). Is UPDATE_SIGNING_KEY the key Resources/UpdatePublicKey.txt was made from?")
    }
    print("Signature OK")

default:
    fail("usage: sign-update.swift sign ZIP | verify PUBLIC_KEY_FILE ZIP SIG_FILE")
}
