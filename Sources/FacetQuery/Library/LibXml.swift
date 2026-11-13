import Foundation
import FacetCore

/// A parsed XML element.
final class XmlElement {
    let name: String
    let namespace: String
    var attributes: [(name: String, value: String)]
    var children: [XmlElement] = []
    var text = ""
    init(name: String, namespace: String, attributes: [(name: String, value: String)]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    var isLeaf: Bool { children.isEmpty && attributes.isEmpty }
    func children(named n: String) -> [XmlElement] { children.filter { $0.name == n } }
    func child(_ n: String) -> XmlElement? { children.first { $0.name == n } }
    func attribute(_ n: String) -> String? { attributes.first { $0.name == n }?.value }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Parse a document; malformed XML is a `DataFormat.Error` naming the line.
    static func parse(_ data: Data, namespaces: Bool = false) throws -> XmlElement {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = namespaces
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription ?? "the document has no root element"
            throw MError.dataFormat("The XML is not valid (line \(parser.lineNumber)): \(reason)")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XmlElement?
        var stack: [XmlElement] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            // XMLParser hands attributes over as a dictionary; sort by name for a stable column order.
            let e = XmlElement(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            if let top = stack.last { top.children.append(e) } else { root = e }
            stack.append(e)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    }
}

extension MLibrary {
    /// The table Power Query builds for a set of same-named sibling elements: one row per element, one column per
    /// child element name (text for simple children that occur at most once, a nested table otherwise), then one
    /// `Attribute:name` column per attribute and `Element:Text` for text beside attributes or children.
    static func xmlTable(_ elements: [XmlElement]) -> MTable {
        var childNames: [String] = [], attributeNames: [String] = [], hasText = false
        for e in elements {
            for c in e.children where !childNames.contains(c.name) { childNames.append(c.name) }
            for a in e.attributes where !attributeNames.contains(a.name) { attributeNames.append(a.name) }
            if !e.trimmedText.isEmpty, !e.isLeaf { hasText = true }
        }
        var names: [String] = [], cols: [[MValue]] = []
        for n in childNames {
            let simple = elements.allSatisfy { e in
                let cs = e.children(named: n)
                return cs.count <= 1 && cs.allSatisfy(\.isLeaf)
            }
            names.append(n)
            cols.append(elements.map { e in
                let cs = e.children(named: n)
                if simple { return cs.first.map { .text($0.text) } ?? .null }
                return cs.isEmpty ? .null : .table(xmlTable(cs))
            })
        }
        if hasText || (childNames.isEmpty && attributeNames.isEmpty) || elements.contains(where: { $0.children.isEmpty && !$0.attributes.isEmpty && !$0.trimmedText.isEmpty }) {
            names.append("Element:Text")
            cols.append(elements.map { $0.trimmedText.isEmpty ? .null : .text($0.text) })
        }
        for n in attributeNames {
            names.append("Attribute:\(n)")
            cols.append(elements.map { e in e.attribute(n).map(MValue.text) ?? .null })
        }
        return MTable(names: MLib.uniqued(names), columns: cols, rowCount: elements.count)
    }

    static func registerXml(_ lib: MLibrary) {
        lib.fn("Xml.Tables", 1...3) { a, ctx in
            let data = try sourceData(a, 0)
            try ctx.checkSize(data.count, of: "The XML document")
            let root = try XmlElement.parse(data)
            var groups: [String] = []
            for c in root.children where !groups.contains(c.name) { groups.append(c.name) }
            let rows = groups.map { n -> [MValue] in
                let members = root.children(named: n)
                if members.count == 1, members[0].isLeaf { return [.text(n), .table(MTable(names: ["Element:Text"], columns: [[.text(members[0].text)]]))] }
                return [.text(n), .table(xmlTable(members))]
            }
            return .table(MTable(names: ["Name", "Table"], types: [.text, .anyTable], rows: rows))
        }
        lib.fn("Xml.Document", 1...2) { a, ctx in
            let data = try sourceData(a, 0)
            try ctx.checkSize(data.count, of: "The XML document")
            func table(_ elements: [XmlElement]) -> MTable {
                MTable(names: ["Name", "Namespace", "Value", "Attributes"], types: [.text, .text, .any, .anyTable], rows: elements.map { e in
                    [.text(e.name), .text(e.namespace), e.children.isEmpty ? .text(e.text) : .table(table(e.children)),
                     .table(MTable(names: ["Name", "Namespace", "Value"], rows: e.attributes.map { [.text($0.name), .text(""), .text($0.value)] }))]
                })
            }
            return .table(table([try XmlElement.parse(data, namespaces: true)]))
        }
    }
}
