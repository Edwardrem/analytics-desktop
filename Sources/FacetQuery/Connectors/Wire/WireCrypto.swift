import Foundation
import CryptoKit

/// Hashes and key derivation used by database authentication (system CryptoKit only).
enum WireCrypto {
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func sha384(_ d: Data) -> Data { Data(SHA384.hash(data: d)) }
    static func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }
    static func md5Hex(_ d: Data) -> String { Data(Insecure.MD5.hash(data: d)).hexString }
    static func hmacSHA256(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
    static func xor(_ a: Data, _ b: Data) -> Data { Data(zip(a, b).map { $0 ^ $1 }) }

    /// RFC 5802 `Hi(str, salt, i)`: PBKDF2 with HMAC-SHA-256 and one output block.
    static func hi(password: Data, salt: Data, iterations: Int) -> Data {
        var u = hmacSHA256(key: password, salt + Data([0, 0, 0, 1]))
        var result = u
        if iterations > 1 {
            for _ in 2...iterations {
                u = hmacSHA256(key: password, u)
                result = xor(result, u)
            }
        }
        return result
    }

    /// Random bytes from the system generator.
    static func random(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    // MARK: Channel binding

    /// RFC 5929 `tls-server-end-point`: the hash of the server certificate, with the hash of its signature algorithm
    /// (SHA-256 for MD5 and SHA-1). Nil when the algorithm doesn't define one (such as Ed25519) or the certificate
    /// can't be read, in which case no channel binding is offered.
    static func tlsServerEndPoint(certificate der: Data) -> Data? {
        guard let oid = signatureAlgorithmOID(der) else { return nil }
        switch oid {
        case "1.2.840.113549.1.1.4", "1.2.840.113549.1.1.5", "1.2.840.113549.1.1.11", "1.2.840.10045.4.1", "1.2.840.10045.4.3.2":
            return sha256(der)
        case "1.2.840.113549.1.1.12", "1.2.840.10045.4.3.3": return sha384(der)
        case "1.2.840.113549.1.1.13", "1.2.840.10045.4.3.4": return sha512(der)
        default: return nil
        }
    }

    /// The dotted OID of a certificate's `signatureAlgorithm` (the second element of the outer SEQUENCE).
    static func signatureAlgorithmOID(_ der: Data) -> String? {
        var r = ByteReader(der, what: "certificate")
        func header(_ r: inout ByteReader) -> (tag: UInt8, length: Int)? {
            guard let tag = try? r.u8(), let first = try? r.u8() else { return nil }
            if first < 0x80 { return (tag, Int(first)) }
            let n = Int(first & 0x7F)
            guard n >= 1, n <= 4, let v = try? r.uintBE(n) else { return nil }
            return (tag, Int(v))
        }
        guard let outer = header(&r), outer.tag == 0x30 else { return nil }
        guard let tbs = header(&r), tbs.tag == 0x30, (try? r.skip(tbs.length)) != nil else { return nil }
        guard let alg = header(&r), alg.tag == 0x30, let oid = header(&r), oid.tag == 0x06, oid.length > 0,
              let body = try? r.bytes(oid.length) else { return nil }
        var parts: [UInt64] = []
        var value: UInt64 = 0
        for b in body {
            guard value < (1 << 56) else { return nil }
            value = value << 7 | UInt64(b & 0x7F)
            if b & 0x80 == 0 {
                if parts.isEmpty {
                    parts = value < 80 ? [value / 40, value % 40] : [2, value - 80]
                } else {
                    parts.append(value)
                }
                value = 0
            }
        }
        return parts.isEmpty ? nil : parts.map(String.init).joined(separator: ".")
    }
}
