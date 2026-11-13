import XCTest
import FacetCore
@testable import FacetQuery

/// JSON, XML and Folder connectors.
final class JsonXmlFolderConnectorTests: FixtureTestCase {
    // MARK: JSON
    func testJsonScalarsRecordsAndLists() throws {
        try write("d.json", """
        {"name": "Ann", "age": 31, "ratio": -1.5e2, "active": true, "none": null,
         "tags": ["a", "b"], "address": {"city": "Oslo", "geo": {"lat": 59.9, "lon": 10.7}}, "empty": {}, "list": []}
        """)
        let v = try eval("Json.Document(File.Contents(\"d.json\"))")
        // fields keep document order
        XCTAssertEqual(v.recordValue?.names, ["name", "age", "ratio", "active", "none", "tags", "address", "empty", "list"])
        XCTAssertEqual(show(v), "[name=Ann,age=31,ratio=-150,active=true,none=null,tags={a,b},address=[city=Oslo,geo=[lat=59.9,lon=10.7]],empty=[],list={}]")
        XCTAssertEqual(try eval("Json.Document(File.Contents(\"d.json\"))[address][geo][lat]").numberValue, 59.9)
        XCTAssertEqual(try eval("Json.Document(File.Contents(\"d.json\"))[tags]{1}").textValue, "b")
    }
    func testJsonArrayOfRecordsToTable() throws {
        try write("rows.json", "[{\"id\":1,\"item\":{\"sku\":\"A\",\"qty\":2}},{\"id\":2,\"item\":{\"sku\":\"B\"}},{\"id\":3,\"item\":null}]")
        let m = """
        let Source = Json.Document(File.Contents("rows.json")),
            T = Table.FromRecords(Source),
            Expanded = Table.ExpandRecordColumn(T, "item", {"sku", "qty"}, {"sku", "qty"})
        in Expanded
        """
        let v = try eval(m)
        XCTAssertEqual(columnNames(v), ["id", "sku", "qty"])
        XCTAssertEqual(try tableRows(v), [["1", "A", "2"], ["2", "B", "null"], ["3", "null", "null"]])
        // the usual "list of records" navigation: to table, then expand
        let viaList = "Table.ExpandRecordColumn(Table.FromList(Json.Document(File.Contents(\"rows.json\")), Splitter.SplitByNothing(), {\"r\"}), \"r\", {\"id\"})"
        XCTAssertEqual(try rows(viaList), [["1"], ["2"], ["3"]])
    }
    func testJsonNestedLists() throws {
        let v = try eval("Json.Document(\"{\"\"orders\"\":[{\"\"id\"\":1,\"\"lines\"\":[10,20]},{\"\"id\"\":2,\"\"lines\"\":[]}]}\")")
        XCTAssertEqual(show(v), "[orders={[id=1,lines={10,20}],[id=2,lines={}]}]")
        let m = "Table.ExpandListColumn(Table.FromRecords(Json.Document(\"{\"\"orders\"\":[{\"\"id\"\":1,\"\"lines\"\":[10,20]},{\"\"id\"\":2,\"\"lines\"\":[]}]}\")[orders]), \"lines\")"
        XCTAssertEqual(try rows(m), [["1", "10"], ["1", "20"], ["2", "null"]])
    }
    func testJsonStringsAndEncodings() throws {
        try write("s.json", "\u{FEFF}{\"t\": \"line\\nbreak \\\"q\\\" \\u00e9 \\ud83d\\ude00 \\/\"}")
        XCTAssertEqual(try eval("Json.Document(File.Contents(\"s.json\"))[t]").textValue, "line\nbreak \"q\" é 😀 /")
        try write("u16.json", Data([0xFF, 0xFE]) + (try XCTUnwrap("{\"k\":\"ü\"}".data(using: .utf16LittleEndian))))
        XCTAssertEqual(try eval("Json.Document(File.Contents(\"u16.json\"))[k]").textValue, "ü")
        try write("w.json", Data([0x22, 0xE9, 0x22])) // "é" in Windows-1252
        XCTAssertEqual(try eval("Json.Document(File.Contents(\"w.json\"), 1252)").textValue, "é")
        XCTAssertEqual(try eval("Json.Document(\"12.5\")").numberValue, 12.5)
        XCTAssertEqual(try eval("Json.Document(\"{\"\"a\"\":1,\"\"a\"\":2}\")[a]").numberValue, 2) // last duplicate wins
        XCTAssertEqual(try eval("Text.FromBinary(Json.FromValue([a = {1, \"x\", null, true}, b = [c = 2.5]]))").textValue, "{\"a\":[1,\"x\",null,true],\"b\":{\"c\":2.5}}")
    }
    func testJsonMalformedInputFailsWithDataFormatError() throws {
        for bad in ["", "{", "{\"a\":}", "[1,2", "{\"a\" 1}", "[1,]", "tru", "{\"a\":1} x", "\"unterminated"] {
            let e = try XCTUnwrap(failure("Json.Document(\(MSyntax.text(bad)))"), "should fail: \(bad)")
            XCTAssertEqual(e.reason, "DataFormat.Error", bad)
        }
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        XCTAssertTrue(try XCTUnwrap(failure("Json.Document(\(MSyntax.text(deep)))")).message.contains("nested too deeply"))
        try write("big.json", "[" + String(repeating: "1,", count: 500) + "1]")
        env.maxSourceBytes = 100
        XCTAssertTrue(try XCTUnwrap(failure("Json.Document(File.Contents(\"big.json\"))")).message.contains("too large"))
    }

    // MARK: XML
    func testXmlTables() throws {
        try write("c.xml", """
        <?xml version="1.0"?>
        <catalog>
          <book id="b1" lang="en"><title>Dune</title><price>9.5</price></book>
          <book id="b2"><title>Emma &amp; Co</title><price>7</price><note><![CDATA[<raw>]]></note></book>
          <owner>Ann</owner>
        </catalog>
        """)
        let v = try eval("Xml.Tables(File.Contents(\"c.xml\"))")
        XCTAssertEqual(columnNames(v), ["Name", "Table"])
        XCTAssertEqual(try eval("Xml.Tables(File.Contents(\"c.xml\"))[Name]").listValue?.map(show), ["book", "owner"])
        let books = try eval("Xml.Tables(File.Contents(\"c.xml\")){[Name = \"book\"]}[Table]")
        XCTAssertEqual(columnNames(books), ["title", "price", "note", "Attribute:id", "Attribute:lang"])
        // element values are text; missing elements and attributes are null
        XCTAssertEqual(try tableRows(books), [["Dune", "9.5", "null", "b1", "en"], ["Emma & Co", "7", "<raw>", "b2", "null"]])
        XCTAssertEqual(try rows("Xml.Tables(File.Contents(\"c.xml\")){[Name = \"owner\"]}[Table]"), [["Ann"]])
    }
    func testXmlNestedRepeatedElementsBecomeNestedTables() throws {
        let xml = "<orders><order n=\"1\"><line sku=\"A\"/><line sku=\"B\"/></order><order n=\"2\"><line sku=\"C\"/></order></orders>"
        let m = "Table.ExpandTableColumn(Xml.Tables(\(MSyntax.text(xml))){0}[Table], \"line\", {\"Attribute:sku\"}, {\"sku\"})"
        let v = try eval(m)
        XCTAssertEqual(columnNames(v), ["sku", "Attribute:n"])
        XCTAssertEqual(try tableRows(v), [["A", "1"], ["B", "1"], ["C", "2"]])
    }
    func testXmlDocumentAndMalformedInput() throws {
        let v = try eval("Xml.Document(\"<a x=\"\"1\"\"><b>t</b></a>\")")
        XCTAssertEqual(columnNames(v), ["Name", "Namespace", "Value", "Attributes"])
        XCTAssertEqual(try eval("Xml.Document(\"<a x=\"\"1\"\"><b>t</b></a>\"){0}[Value]{0}[Value]").textValue, "t")
        XCTAssertEqual(try rows("Xml.Document(\"<a x=\"\"1\"\"><b>t</b></a>\"){0}[Attributes]"), [["x", "", "1"]])
        let e = try XCTUnwrap(failure("Xml.Tables(\"<a><b></a>\")"))
        XCTAssertEqual(e.reason, "DataFormat.Error")
        XCTAssertTrue(e.message.contains("line 1"), e.message)
        XCTAssertEqual(try XCTUnwrap(failure("Xml.Tables(\"\")")).reason, "DataFormat.Error")
    }

    // MARK: Folder
    func testFolderFilesListsRecursivelyWithLazyContent() throws {
        try write("data/2024/jan.csv", "m,v\njan,1\n")
        try write("data/2024/feb.csv", "m,v\nfeb,2\n")
        try write("data/notes.txt", "hello")
        try write("data/.hidden.csv", "m,v\nx,9\n")
        let v = try eval("Folder.Files(\"data\")")
        XCTAssertEqual(columnNames(v), ["Content", "Name", "Extension", "Date accessed", "Date modified", "Date created", "Attributes", "Folder Path"])
        // every file below the folder, sorted by path
        XCTAssertEqual(try eval("Folder.Files(\"data\")[Name]").listValue?.map(show), [".hidden.csv", "feb.csv", "jan.csv", "notes.txt"])
        XCTAssertEqual(try eval("Folder.Files(\"data\")[Extension]").listValue?.map(show), [".csv", ".csv", ".csv", ".txt"])
        let folder = try XCTUnwrap(try eval("Folder.Files(\"data\"){[Name = \"jan.csv\"]}[Folder Path]").textValue)
        XCTAssertTrue(folder.hasSuffix("/data/2024/"), folder)
        XCTAssertEqual(try eval("Folder.Files(\"data\"){[Name = \"notes.txt\"]}[Attributes][Size]").numberValue, 5)
        XCTAssertEqual(try eval("Folder.Files(\"data\"){[Name = \".hidden.csv\"]}[Attributes][Hidden]").logicalValue, true)
        XCTAssertEqual(try eval("Folder.Files(\"data\"){[Name = \"jan.csv\"]}[Attributes][Hidden]").logicalValue, false)
        XCTAssertEqual(try eval("Text.FromBinary(Folder.Files(\"data\"){[Name = \"notes.txt\"]}[Content])").textValue, "hello")
        XCTAssertTrue(try XCTUnwrap(try eval("Folder.Files(\"data\"){0}[Date modified] is datetime").logicalValue))
        // Folder.Contents is one level deep and includes sub-folders
        XCTAssertEqual(try eval("Folder.Contents(\"data\")[Name]").listValue?.map(show), [".hidden.csv", "2024", "notes.txt"])
        XCTAssertEqual(try eval("Folder.Contents(\"data\"){[Name = \"2024\"]}[Content][Name]").listValue?.map(show), ["feb.csv", "jan.csv"])
    }
    func testCombineFilesFromFolder() throws {
        try write("data/a.csv", "m,v\njan,1\nfeb,2\n")
        try write("data/b.csv", "m,v\nmar,3\n")
        try write("data/.hidden.csv", "m,v\nx,9\n")
        var script = "let\n    Source = Folder.Files(\"data\")\nin\n    Source"
        script = MScript.appending(.combineFiles(.csv(delimiter: ",", promoteHeaders: true)), to: script)
        let v = try MInterpreter(environment: env).evaluate(script)
        // hidden files are skipped; each file's rows carry its name
        XCTAssertEqual(columnNames(v), ["m", "v", "Source.Name"])
        XCTAssertEqual(try tableRows(v), [["jan", "1", "a.csv"], ["feb", "2", "a.csv"], ["mar", "3", "b.csv"]])
    }
    func testCombineJsonFilesFromFolder() throws {
        try write("j/1.json", "[{\"k\":1}]")
        try write("j/2.json", "[{\"k\":2},{\"k\":3}]")
        let script = MScript.appending(.combineFiles(.json), to: "let\n    Source = Folder.Files(\"j\")\nin\n    Source")
        XCTAssertEqual(try tableRows(try eval(script)), [["1", "1.json"], ["2", "2.json"], ["3", "2.json"]])
    }
    func testFolderErrors() throws {
        let e = try XCTUnwrap(failure("Folder.Files(\"missing\")"))
        XCTAssertEqual(e.reason, "DataSource.Error")
        XCTAssertTrue(e.message.contains("missing"))
        try write("f.txt", "x")
        XCTAssertEqual(try XCTUnwrap(failure("Folder.Files(\"f.txt\")")).reason, "DataSource.Error")
    }
    func testUnavailableConnectorsFailClearly() throws {
        for call in ["Parquet.Document(#binary({1}))", "Pdf.Tables(#binary({1}))", "Sql.Database(\"srv\", \"db\")", "Odbc.DataSource(\"dsn\")",
                     "PostgreSQL.Database(\"h\", \"d\")", "MySQL.Database(\"h\", \"d\")"] {
            let e = try XCTUnwrap(failure(call), call)
            XCTAssertEqual(e.reason, "DataSource.Error", call)
            XCTAssertTrue(e.message.contains("isn't available"), e.message)
        }
    }
}
