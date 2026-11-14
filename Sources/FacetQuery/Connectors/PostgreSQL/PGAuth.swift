import Foundation

/// SCRAM-SHA-256 client (RFC 5802 and RFC 7677), with `tls-server-end-point` channel binding (SCRAM-SHA-256-PLUS).
struct SCRAMClient {
    /// The most PBKDF2 iterations accepted from a server, so a hostile server can't make the client spin.
    static let maxIterations = 1_000_000

    let user: String
    let password: String
    let clientNonce: String
    /// "n,," (no binding), "y,," (client could bind, server didn't offer it) or "p=tls-server-end-point,,".
    let gs2Header: String
    let channelBinding: Data
    private(set) var serverSignature: Data?

    init(user: String, password: String, clientNonce: String = WireCrypto.random(18).base64EncodedString(),
         gs2Header: String = "n,,", channelBinding: Data = Data()) {
        self.user = user; self.password = password; self.clientNonce = clientNonce
        self.gs2Header = gs2Header; self.channelBinding = channelBinding
    }

    /// Chooses the mechanism and binding from the server's list: PLUS when it is offered and the certificate gives a
    /// binding; "y" when TLS is on but the server doesn't offer PLUS.
    static func choose(mechanisms: [String], tls: Bool, binding: Data?) throws -> (mechanism: String, gs2: String, binding: Data) {
        if mechanisms.contains("SCRAM-SHA-256-PLUS"), let binding {
            return ("SCRAM-SHA-256-PLUS", "p=tls-server-end-point,,", binding)
        }
        guard mechanisms.contains("SCRAM-SHA-256") else {
            throw WireError("The server asked for SASL authentication with \(mechanisms.joined(separator: ", ")), which isn't supported. Supported: SCRAM-SHA-256.")
        }
        // Only claim binding support when the server didn't offer it; otherwise it would see a downgrade.
        return ("SCRAM-SHA-256", tls && !mechanisms.contains("SCRAM-SHA-256-PLUS") ? "y,," : "n,,", Data())
    }

    static func saslName(_ s: String) -> String {
        s.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    var clientFirstBare: String { "n=\(Self.saslName(user)),r=\(clientNonce)" }
    var clientFirst: String { gs2Header + clientFirstBare }

    /// SASLprep for the common case: compatibility-normalised text (RFC 4013 maps and normalises with NFKC).
    static func prepare(_ password: String) -> String { password.precomposedStringWithCompatibilityMapping }

    /// The client-final message for the server-first message; remembers the signature the server must prove.
    mutating func clientFinal(serverFirst: String) throws -> String {
        var fields: [Character: String] = [:]
        for part in serverFirst.split(separator: ",", omittingEmptySubsequences: false) {
            guard part.count >= 2, part.dropFirst().first == "=", let key = part.first else { continue }
            if fields[key] == nil { fields[key] = String(part.dropFirst(2)) }
        }
        if let e = fields["e"] { throw WireError("The server rejected the sign-in: \(e).") }
        guard let nonce = fields["r"], nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count else {
            throw WireError("The server's SCRAM nonce doesn't extend the client's; the sign-in was stopped.")
        }
        guard let saltText = fields["s"], let salt = Data(base64Encoded: saltText), !salt.isEmpty else { throw WireError.malformed("SCRAM salt") }
        guard let iText = fields["i"], let iterations = Int(iText), iterations >= 1, iterations <= Self.maxIterations else {
            throw WireError("The server asked for an unreasonable SCRAM iteration count.")
        }
        let salted = WireCrypto.hi(password: Data(Self.prepare(password).utf8), salt: salt, iterations: iterations)
        let clientKey = WireCrypto.hmacSHA256(key: salted, Data("Client Key".utf8))
        let storedKey = WireCrypto.sha256(clientKey)
        let binding = (Data(gs2Header.utf8) + channelBinding).base64EncodedString()
        let withoutProof = "c=\(binding),r=\(nonce)"
        let authMessage = Data((clientFirstBare + "," + serverFirst + "," + withoutProof).utf8)
        let signature = WireCrypto.hmacSHA256(key: storedKey, authMessage)
        let proof = WireCrypto.xor(clientKey, signature)
        let serverKey = WireCrypto.hmacSHA256(key: salted, Data("Server Key".utf8))
        serverSignature = WireCrypto.hmacSHA256(key: serverKey, authMessage)
        return withoutProof + ",p=" + proof.base64EncodedString()
    }

    /// Checks the server-final message: the server must prove it knows the password too.
    func verify(serverFinal: String) throws {
        if serverFinal.hasPrefix("e=") { throw WireError("The server rejected the sign-in: \(serverFinal.dropFirst(2)).") }
        guard serverFinal.hasPrefix("v="), let expected = serverSignature,
              let got = Data(base64Encoded: String(serverFinal.dropFirst(2).prefix { $0 != "," })), got == expected else {
            throw WireError("The server's SCRAM signature is wrong; it may not be the server it claims to be. The connection was closed.")
        }
    }
}

enum PGPassword {
    /// `md5` authentication: "md5" + md5(md5(password + user) + salt), in hex.
    static func md5(user: String, password: String, salt: Data) -> String {
        let inner = WireCrypto.md5Hex(Data((password + user).utf8))
        return "md5" + WireCrypto.md5Hex(Data(inner.utf8) + salt)
    }
}
