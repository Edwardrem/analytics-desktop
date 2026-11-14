import XCTest
@testable import FacetQuery

/// Web.Contents sends stored credentials only to the source they were saved for.
final class WebCredentialRedirectTests: XCTestCase {
    private func redirect(to url: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Basic ZmFrZTpmYWtl", forHTTPHeaderField: "Authorization")
        r.setValue("fake-key", forHTTPHeaderField: "X-Api-Key")
        r.setValue("text/csv", forHTTPHeaderField: "Accept")
        return r
    }

    private let secrets: Set<String> = ["authorization", "x-api-key"]

    func testSameHostAndSchemeKeepsCredentials() {
        let r = WebCredentialRedirectGuard.guarded(redirect(to: "https://data.example.com/v2/file.csv"),
                                                   host: "data.example.com", scheme: "https", secretHeaders: secrets)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic ZmFrZTpmYWtl")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Api-Key"), "fake-key")
    }

    func testOtherHostDropsCredentialsButKeepsOtherHeaders() {
        for target in ["https://evil.example.net/file.csv", "https://data.example.com.evil.net/file.csv"] {
            let r = WebCredentialRedirectGuard.guarded(redirect(to: target), host: "data.example.com", scheme: "https", secretHeaders: secrets)
            XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"), target)
            XCTAssertNil(r.value(forHTTPHeaderField: "X-Api-Key"), target)
            XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "text/csv", target)
        }
    }

    func testDowngradeToHttpDropsCredentials() {
        let r = WebCredentialRedirectGuard.guarded(redirect(to: "http://data.example.com/file.csv"),
                                                   host: "data.example.com", scheme: "https", secretHeaders: secrets)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }
}
