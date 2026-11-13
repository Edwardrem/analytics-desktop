import XCTest
import FacetCore
@testable import FacetQuery

/// Excel workbook connector. The fixture is a hand-written .xlsx (Office Open XML parts in a ZIP).
final class ExcelConnectorTests: FixtureTestCase {
    static let ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
    static let relNS = "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\""

    /// Sales (4 x 4 with shared, inline and formula strings, dates, booleans, an error), a hidden sheet,
    /// a Data sheet holding the table "Products" at B2:C4, and the defined name TopLeft = Sales!A1:B2.
    static func parts(date1904: Bool = false) -> [(String, String)] {
        let workbook = """
        <workbook \(ns)>\(date1904 ? "<workbookPr date1904=\"1\"/>" : "")
          <sheets><sheet name="Sales" sheetId="1" r:id="rId1"/><sheet name="Hidden Notes" sheetId="2" state="hidden" r:id="rId2"/><sheet name="Data" sheetId="3" r:id="rId3"/></sheets>
          <definedNames><definedName name="TopLeft">Sales!$A$1:$B$2</definedName><definedName name="_xlnm.Print_Area" localSheetId="0">Sales!$A$1:$D$4</definedName></definedNames>
        </workbook>
        """
        let workbookRels = """
        <Relationships \(relNS)>
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet2.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
          <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
          <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        // index 0 is rich text in two runs with a phonetic hint that must be ignored
        let shared = """
        <sst \(ns) count="8" uniqueCount="8">
          <si><r><t>Re</t></r><r><t>gion</t></r><rPh sb="0" eb="1"><t>IGNORED</t></rPh></si>
          <si><t>Amount</t></si><si><t>Date</t></si><si><t xml:space="preserve"> North </t></si><si><t>Paid</t></si>
          <si><t>SKU</t></si><si><t>Qty</t></si><si><t>junk</t></si>
        </sst>
        """
        // cell styles: 0 general, 1 built-in date (14), 2 custom date-time, 3 built-in time (20), 4 custom number with a quoted "d"
        let styles = """
        <styleSheet \(ns)>
          <numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd\\ hh:mm"/><numFmt numFmtId="165" formatCode="0.0 &quot;days&quot;"/></numFmts>
          <cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="20"/><xf numFmtId="165"/></cellXfs>
        </styleSheet>
        """
        let sales = """
        <worksheet \(ns)><dimension ref="A1:D4"/><sheetData>
          <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>4</v></c></row>
          <row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2"><v>100.5</v></c><c r="C2" s="1"><v>45292</v></c><c r="D2" t="b"><v>1</v></c></row>
          <row r="3"><c r="A3" t="inlineStr"><is><t>South</t></is></c><c r="B3" s="4"><v>200</v></c><c r="C3" s="2"><v>45323.5</v></c><c r="D3" t="b"><v>0</v></c></row>
          <row r="4"><c r="A4" t="str"><f>"Ea"&amp;"st"</f><v>East</v></c><c r="C4" s="3"><v>0.75</v></c><c r="D4" t="e"><v>#DIV/0!</v></c></row>
        </sheetData></worksheet>
        """
        let hidden = "<worksheet \(ns)><sheetData/></worksheet>"
        let data = """
        <worksheet \(ns)><sheetData>
          <row r="1"><c r="A1" t="s"><v>7</v></c></row>
          <row r="2"><c r="B2" t="s"><v>5</v></c><c r="C2" t="s"><v>6</v></c></row>
          <row r="3"><c r="B3" t="inlineStr"><is><t>A-1</t></is></c><c r="C3"><v>5</v></c></row>
          <row r="4"><c r="B4" t="inlineStr"><is><t>B-2</t></is></c><c r="C4"><v>7</v></c></row>
        </sheetData><tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>
        """
        let dataRels = "<Relationships \(relNS)><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" Target=\"../tables/table1.xml\"/></Relationships>"
        let table = "<table \(ns) id=\"1\" name=\"Table1\" displayName=\"Products\" ref=\"B2:C4\"><tableColumns count=\"2\"><tableColumn id=\"1\" name=\"SKU\"/><tableColumn id=\"2\" name=\"Qty\"/></tableColumns></table>"
        return [("[Content_Types].xml", "<Types/>"), ("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", workbookRels),
                ("xl/sharedStrings.xml", shared), ("xl/styles.xml", styles), ("xl/worksheets/sheet1.xml", sales),
                ("xl/worksheets/sheet2.xml", hidden), ("xl/worksheets/sheet3.xml", data), ("xl/worksheets/_rels/sheet3.xml.rels", dataRels),
                ("xl/tables/table1.xml", table)]
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        try write("book.xlsx", TestZip.archive(Self.parts()))
    }
    private let book = "Excel.Workbook(File.Contents(\"book.xlsx\"))"

    func testNavigationTableListsSheetsTablesAndDefinedNames() throws {
        let v = try eval(book)
        XCTAssertEqual(columnNames(v), ["Name", "Data", "Item", "Kind", "Hidden"])
        XCTAssertEqual(try rows("Table.SelectColumns(\(book), {\"Name\", \"Kind\", \"Hidden\"})"),
                       [["Sales", "Sheet", "false"], ["Hidden Notes", "Sheet", "true"], ["Data", "Sheet", "false"],
                        ["Products", "Table", "false"], ["TopLeft", "DefinedName", "false"]])
    }
    func testSheetCellsSharedInlineAndFormulaStringsNumbersBooleans() throws {
        let v = try eval("\(book){[Item = \"Sales\", Kind = \"Sheet\"]}[Data]")
        XCTAssertEqual(columnNames(v), ["Column1", "Column2", "Column3", "Column4"])
        XCTAssertEqual(try tableRows(v), [
            ["Region", "Amount", "Date", "Paid"],
            [" North ", "100.5", "#datetime(2024, 1, 1, 0, 0, 0)", "true"],
            ["South", "200", "#datetime(2024, 2, 1, 12, 0, 0)", "false"],
            ["East", "null", "#time(18, 0, 0)", "<error>"],
        ])
        // the Excel error is a cell error naming the Excel error value
        let e = try XCTUnwrap(failure("\(book){0}[Data][Column4]{3}"))
        XCTAssertTrue(e.message.contains("#DIV/0!"), e.message)
        // an empty sheet has no rows
        XCTAssertEqual(try rows("\(book){[Item = \"Hidden Notes\", Kind = \"Sheet\"]}[Data]"), [])
    }
    func testUseHeadersPromotesFirstRow() throws {
        let v = try eval("Excel.Workbook(File.Contents(\"book.xlsx\"), true){[Item = \"Sales\", Kind = \"Sheet\"]}[Data]")
        XCTAssertEqual(columnNames(v), ["Region", "Amount", "Date", "Paid"])
        XCTAssertEqual(try tableRows(v).count, 3)
        XCTAssertEqual(columnNames(try eval("Excel.Workbook(File.Contents(\"book.xlsx\"), [UseHeaders = true]){0}[Data]")), ["Region", "Amount", "Date", "Paid"])
        // the script Get Data writes for an Excel file
        let script = "let\n    Source = Excel.Workbook(File.Contents(\"book.xlsx\"), null, true),\n    First = Source{0}[Data],\n    Promoted = Table.PromoteHeaders(First, [PromoteAllScalars = true])\nin\n    Promoted"
        XCTAssertEqual(try eval("(\(script))[Amount]").listValue?.map(show), ["100.5", "200", "null"])
    }
    func testTablesUseTheirHeaderNamesAndRange() throws {
        let v = try eval("\(book){[Item = \"Products\", Kind = \"Table\"]}[Data]")
        XCTAssertEqual(columnNames(v), ["SKU", "Qty"])
        XCTAssertEqual(try tableRows(v), [["A-1", "5"], ["B-2", "7"]])
        // the sheet holding the table starts at its first used cell and pads with null
        XCTAssertEqual(try rows("\(book){[Item = \"Data\", Kind = \"Sheet\"]}[Data]"),
                       [["junk", "null", "null"], ["null", "SKU", "Qty"], ["null", "A-1", "5"], ["null", "B-2", "7"]])
    }
    func testDefinedNameRange() throws {
        XCTAssertEqual(try rows("\(book){[Item = \"TopLeft\", Kind = \"DefinedName\"]}[Data]"), [["Region", "Amount"], [" North ", "100.5"]])
    }
    func testDate1904Workbook() throws {
        try write("mac.xlsx", TestZip.archive(Self.parts(date1904: true)))
        // serial 45292 counted from 1 January 1904 is 1462 days later than in the 1900 system: 2024-01-01 + 4 years 1 day
        XCTAssertEqual(show(try eval("Excel.Workbook(File.Contents(\"mac.xlsx\")){0}[Data][Column3]{1}")), "#datetime(2028, 1, 2, 0, 0, 0)")
    }
    func testDeflatedWorkbook() throws {
        let zipTool = "/usr/bin/zip"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: zipTool), "zip tool not available")
        let staging = dir.appendingPathComponent("staging")
        for (name, text) in Self.parts() { try write("staging/" + name, text) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zipTool)
        p.currentDirectoryURL = staging
        p.arguments = ["-q", "-r", "-9", "../deflated.xlsx", "."]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(try rows("Excel.Workbook(File.Contents(\"deflated.xlsx\")){[Item = \"Products\", Kind = \"Table\"]}[Data]"), [["A-1", "5"], ["B-2", "7"]])
        XCTAssertEqual(try eval("Excel.Workbook(File.Contents(\"deflated.xlsx\")){0}[Data][Column1]").listValue?.map(show), ["Region", " North ", "South", "East"])
    }
    func testDateFormatDetection() {
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "General"), 0)
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "#,##0.00"), 0)
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "0.0 \"days\""), 0)
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "[$-409]d\\-mmm\\-yy"), 1)
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "dd/mm/yyyy hh:mm"), 1)
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "h:mm:ss AM/PM"), 2)
        XCTAssertEqual(XlsxWorkbook.dateKind(formatCode: "[h]:mm"), 2)
    }
    func testCellReferences() {
        XCTAssertEqual(XlsxWorkbook.cell("A1")?.column, 0)
        XCTAssertEqual(XlsxWorkbook.cell("Z10")?.column, 25)
        XCTAssertEqual(XlsxWorkbook.cell("AA3")?.column, 26)
        XCTAssertEqual(XlsxWorkbook.cell("AB12")?.row, 11)
        XCTAssertNil(XlsxWorkbook.cell("12"))
        let r = XlsxWorkbook.range("B2:D5")
        XCTAssertEqual([r?.firstRow, r?.firstColumn, r?.lastRow, r?.lastColumn], [1, 1, 4, 3])
    }
    func testMalformedWorkbooksFailClearly() throws {
        try write("text.xlsx", "this is not a zip archive at all, just some text")
        let notZip = try XCTUnwrap(failure("Excel.Workbook(File.Contents(\"text.xlsx\"))"))
        XCTAssertEqual(notZip.reason, "DataFormat.Error")
        XCTAssertTrue(notZip.message.contains("ZIP"), notZip.message)
        try write("other.xlsx", TestZip.archive([("readme.txt", "hi")]))
        let noBook = try XCTUnwrap(failure("Excel.Workbook(File.Contents(\"other.xlsx\"))"))
        XCTAssertEqual(noBook.reason, "DataFormat.Error")
        XCTAssertTrue(noBook.message.contains("workbook"), noBook.message)
        let whole = TestZip.archive(Self.parts())
        try write("cut.xlsx", whole.prefix(whole.count - 40))
        XCTAssertEqual(try XCTUnwrap(failure("Excel.Workbook(File.Contents(\"cut.xlsx\"))")).reason, "DataFormat.Error")
        var broken = Self.parts()
        broken[5].1 = "<worksheet><sheetData><row>"
        try write("broken.xlsx", TestZip.archive(broken))
        // the workbook opens; the damaged sheet fails only when its data is read
        XCTAssertEqual(try rows("Excel.Workbook(File.Contents(\"broken.xlsx\")){[Item = \"Products\", Kind = \"Table\"]}[Data]").count, 2)
        let sheet = try XCTUnwrap(failure("Table.RowCount(Excel.Workbook(File.Contents(\"broken.xlsx\")){0}[Data])"))
        XCTAssertTrue(sheet.message.contains("xl/worksheets/sheet1.xml"), sheet.message)
        XCTAssertNotNil(failure("Excel.Workbook(\"text\")"))
    }
    func testOversizedWorkbookIsRefused() throws {
        env.maxSourceBytes = 1000
        let e = try XCTUnwrap(failure(book))
        XCTAssertEqual(e.reason, "DataSource.Error")
        XCTAssertTrue(e.message.contains("too large"), e.message)
    }
}
