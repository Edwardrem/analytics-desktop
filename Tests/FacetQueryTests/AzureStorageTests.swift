import XCTest
import FacetCore
@testable import FacetQuery

/// `AzureStorage.Blobs` and `AzureStorage.DataLake` (ADLS Gen2 and OneLake) against `URLProtocol` stubs.
/// Keys, SAS tokens and bearer tokens are obvious fakes.
final class AzureStorageTests: CloudStubTestCase {
    private let storageToken = "Bearer FAKE-TOKEN-for-https://storage.azure.com/.default"

    private func blobService() {
        CloudStub.handler = { r in
            let q = r.url?.query ?? ""
            switch r.url?.path {
            case "/"? where !q.contains("marker="):
                return .bytes(Data("<EnumerationResults><Containers><Container><Name>data</Name></Container></Containers><NextMarker>m2</NextMarker></EnumerationResults>".utf8))
            case "/"?:
                return .bytes(Data("<EnumerationResults><Containers><Container><Name>logs</Name></Container></Containers><NextMarker/></EnumerationResults>".utf8))
            case "/data"?:
                return .bytes(Data(("<EnumerationResults><Blobs><Blob><Name>2026/sales.csv</Name><Properties><Content-Length>5</Content-Length>" +
                                    "<Last-Modified>Thu, 01 Jan 2026 00:00:00 GMT</Last-Modified></Properties></Blob><Blob><Name>dir/</Name></Blob></Blobs><NextMarker/></EnumerationResults>").utf8))
            case "/data/2026/sales.csv"?: return .bytes(Data("a\n1\n2".utf8))
            default: return CloudStub.Response(status: 404)
            }
        }
    }

    func testBlobsListContainersAcrossPagesWithAnEntraToken() throws {
        blobService()
        XCTAssertEqual(try rows(#"Table.SelectColumns(AzureStorage.Blobs("acct"), {"Name", "Kind"})"#), [["data", "Folder"], ["logs", "Folder"]])
        XCTAssertTrue(CloudStub.requests.allSatisfy { $0.url?.host == "acct.blob.core.windows.net" && bearer($0) == storageToken })
        XCTAssertTrue(CloudStub.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-ms-version") == "2023-11-03" })
        XCTAssertEqual(CloudStub.requests.last?.url?.query?.contains("marker=m2"), true)
    }

    func testBlobsInAContainerAreFilesWithContent() throws {
        blobService()
        env.timeZone = TimeZone(identifier: "UTC") ?? .current
        let files = #"AzureStorage.Blobs("https://acct.blob.core.windows.net/data")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(files), {\"Name\", \"Folder Path\", \"Date modified\"})"),
                       [["2026/sales.csv", "https://acct.blob.core.windows.net/data/", "#datetime(2026, 1, 1, 0, 0, 0)"]])
        XCTAssertEqual(try eval("Text.FromBinary(\(files){0}[Content])").textValue, "a\n1\n2")
    }

    func testSasTokenIsSentInTheQueryWithoutAnAuthorizationHeader() throws {
        blobService()
        creds.stored["AzureBlobs|https://acct.blob.core.windows.net"] = .sasToken("?sv=2022-11-02&sig=FAKE-SIGNATURE")
        _ = try rows(#"AzureStorage.Blobs("acct")"#)
        XCTAssertFalse(CloudStub.requests.isEmpty)
        for r in CloudStub.requests {
            XCTAssertNil(bearer(r))
            XCTAssertTrue(r.url?.query?.contains("sig=FAKE-SIGNATURE") ?? false)
        }
        XCTAssertTrue(creds.calls.isEmpty, "no Entra token is asked for")
    }

    func testAnonymousAccessSendsNoCredentials() throws {
        blobService()
        creds.stored["AzureBlobs|https://acct.blob.core.windows.net"] = .anonymous
        _ = try rows(#"AzureStorage.Blobs("acct")"#)
        XCTAssertTrue(CloudStub.requests.allSatisfy { bearer($0) == nil })
    }

    func testAccountKeySignsEachRequest() throws {
        blobService()
        creds.stored["AzureBlobs|https://acct.blob.core.windows.net"] = .accountKey("RkFLRS1LRVktMDEyMzQ1Njc4OQ==")
        _ = try rows(#"AzureStorage.Blobs("acct")"#)
        for r in CloudStub.requests {
            XCTAssertTrue(bearer(r)?.hasPrefix("SharedKey acct:") ?? false)
            XCTAssertNotNil(r.value(forHTTPHeaderField: "x-ms-date"))
        }
    }

    func testSharedKeySignatureMatchesTheDocumentedStringToSign() {
        // Key = Base64("FAKE-KEY-0123456789"). The expected value is HMAC-SHA256 over
        // "GET\n" + 11 empty headers + "x-ms-date:…\nx-ms-version:2023-11-03\n/acct/data\ncomp:list\nrestype:container",
        // worked out independently with Python's hmac module.
        let key = Data("FAKE-KEY-0123456789".utf8)
        let value = AzureStorageSource.sharedKey(
            account: "acct", key: key, method: "GET", path: "/data",
            query: [URLQueryItem(name: "restype", value: "container"), URLQueryItem(name: "comp", value: "list")],
            headers: ["x-ms-version": "2023-11-03", "x-ms-date": "Thu, 01 Jan 2026 00:00:00 GMT"])
        XCTAssertEqual(value, "SharedKey acct:8pMg+1bG/dCh2FKhkvBACGWYuMFzQC6WhkeSqPpXgeo=")
    }

    func testRefusedStorageRequestAsksForCredentials() throws {
        CloudStub.handler = { _ in CloudStub.Response(status: 403, headers: [:], body: Data("<Error><Message>AuthorizationFailure</Message></Error>".utf8)) }
        let e = try XCTUnwrap(failure(#"AzureStorage.Blobs("acct")"#))
        XCTAssertEqual(e.credentialSource?.kind, "AzureBlobs")
        XCTAssertEqual(e.credentialSource?.location, "https://acct.blob.core.windows.net")
        XCTAssertTrue(e.message.contains("AuthorizationFailure"), e.message)
    }

    func testBlobsRefuseLookAlikeHosts() throws {
        CloudStub.handler = { _ in .json("{}") }
        for account in ["https://acct.blob.core.windows.net.evil.com", "https://acctblob.core.windows.net", "http://acct.blob.core.windows.net"] {
            XCTAssertNotNil(failure("AzureStorage.Blobs(\"\(account)\")"), account)
        }
        XCTAssertTrue(CloudStub.requests.isEmpty)
    }

    // MARK: Data Lake

    func testDataLakeFollowsContinuationAndSkipsDirectories() throws {
        CloudStub.handler = { r in
            let q = r.url?.query ?? ""
            guard r.url?.path == "/fs" else { return r.url?.path == "/fs/raw/b.csv" ? .bytes(Data("z".utf8)) : CloudStub.Response(status: 404) }
            if !q.contains("continuation=") {
                return CloudStub.Response(headers: ["Content-Type": "application/json", "x-ms-continuation": "next1"],
                                          body: Data(#"{"paths":[{"name":"raw","isDirectory":"true"},{"name":"raw/b.csv","contentLength":"1"}]}"#.utf8))
            }
            return .json(#"{"paths":[{"name":"a.csv","contentLength":"3"}]}"#)
        }
        let lake = #"AzureStorage.DataLake("https://acct.dfs.core.windows.net/fs")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(lake), {\"Name\", \"Folder Path\"})"), [
            ["a.csv", "https://acct.dfs.core.windows.net/fs/"],
            ["b.csv", "https://acct.dfs.core.windows.net/fs/raw/"],
        ])
        XCTAssertEqual(try eval("Text.FromBinary(\(lake){[Name=\"b.csv\"]}[Content])").textValue, "z")
        XCTAssertTrue(CloudStub.requests.contains { $0.url?.query?.contains("continuation=next1") ?? false })
    }

    func testOneLakeUsesTheStorageTokenForOneLakesHost() throws {
        CloudStub.handler = { _ in .json(#"{"paths":[{"name":"Lake.Lakehouse/Files/x.parquet","contentLength":"4"}]}"#) }
        let lake = #"AzureStorage.DataLake("https://onelake.dfs.fabric.microsoft.com/Sales/Lake.Lakehouse/Files")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(lake), {\"Name\"})"), [["x.parquet"]])
        XCTAssertEqual(CloudStub.requests.first?.url?.query?.contains("directory=Lake.Lakehouse/Files"), true)
        XCTAssertEqual(creds.calls.map(\.host), ["onelake.dfs.fabric.microsoft.com"])
        XCTAssertEqual(creds.calls.map(\.resource), [EntraResource.storage])
    }

    func testDataLakeRefusesOtherHosts() throws {
        CloudStub.handler = { _ in .json("{}") }
        for address in ["https://acct.blob.core.windows.net/fs", "https://onelake.dfs.fabric.microsoft.com.evil.com/w", "https://acct.dfs.core.windows.net.evil.com/fs"] {
            XCTAssertNotNil(failure("AzureStorage.DataLake(\"\(address)\")"), address)
        }
        XCTAssertTrue(CloudStub.requests.isEmpty)
    }
}
