import XCTest
@testable import FacetVisuals

/// `TextBoxPlaceholders.names`: the `{{…}}` bodies a text box asks the app to evaluate.
final class TextBoxPlaceholderTests: XCTestCase {
    func testNamesInOrderOfFirstUse() {
        let text = "# {{Total Sales}}\nSold **{{=SUM(Sales[Amount])}}**, again {{ Total Sales }}.\n- {{Top Region}}"
        XCTAssertEqual(TextBoxPlaceholders.names(in: text), ["Total Sales", "=SUM(Sales[Amount])", "Top Region"])
    }

    func testEscapedAndUnclosedBracesAreText() {
        XCTAssertEqual(TextBoxPlaceholders.names(in: #"Literal \{{not a value}} and {{open"#), [])
        XCTAssertEqual(TextBoxPlaceholders.names(in: "No values here"), [])
        XCTAssertEqual(TextBoxPlaceholders.names(in: "{{}} {{Margin}}"), ["Margin"])
    }
}
