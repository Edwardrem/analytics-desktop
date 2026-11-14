import SwiftUI
import FacetCore
import FacetDesign

/// The Power Query Editor ribbon as data: tab → group → items naming `EditorCommands` ids, laid out as
/// Power BI Desktop's editor (Home, Transform, Add Column, View, Tools).
@MainActor
enum EditorRibbonLayout {
    indirect enum Entry {
        case command(String)
        case divider
        case submenu(String, [Entry])
    }
    enum Item {
        case button(String)
        case menu(title: String, symbol: String, [Entry])
    }
    struct Group { var title: String; var items: [Item] }
    struct Tab: Identifiable { var title: String; var groups: [Group]; var id: String { title } }

    private static func cmds(_ ids: [String]) -> [Entry] { ids.map { .command($0) } }

    static let dataType: Item = .menu(title: "Data Type", symbol: "textformat.123",
                                      cmds(DataTypeCommands.types.map { DataTypeCommands.id($0.type) }) + [.divider, .command("pq.typeLocale")])
    static let split: Item = .menu(title: "Split Column", symbol: "scissors", cmds([
        "pq.splitDelimiter", "pq.splitLength", "pq.splitPositions", "pq.splitLowerUpper", "pq.splitUpperLower", "pq.splitDigitNonDigit", "pq.splitNonDigitDigit",
    ]))
    static let headers: Item = .menu(title: "Use First Row as Headers", symbol: "text.line.first.and.arrowtriangle.forward", cmds(["pq.promoteHeaders", "pq.demoteHeaders"]))

    static func format(_ prefix: String) -> Item {
        .menu(title: "Format", symbol: "textformat", cmds(ColumnOperationCommands.textFormats.map { "\(prefix).text.\($0.0.rawValue)" })
              + (prefix == "pq" ? [.divider, .command("pq.prefix"), .command("pq.suffix")] : []))
    }
    static func extract(_ prefix: String) -> Item {
        .menu(title: "Extract", symbol: "text.viewfinder", cmds(ColumnOperationCommands.extracts.map { "\(prefix).extract.\($0.0)" }))
    }
    static func parse(_ prefix: String) -> Item {
        .menu(title: "Parse", symbol: "curlybraces", cmds(prefix == "pq" ? ["pq.parseXML", "pq.parseJSON"] : ["pq.add.parseXML", "pq.add.parseJSON"]))
    }
    static func statistics(_ prefix: String) -> Item {
        .menu(title: "Statistics", symbol: "sum", cmds(ColumnOperationCommands.statistics.map { "\(prefix).stat.\($0.0.rawValue)" }))
    }
    static func standard(_ prefix: String) -> Item {
        .menu(title: "Standard", symbol: "plus.forwardslash.minus", cmds(["add", "multiply", "subtract", "divide", "integerDivide", "modulo", "percentage", "percentOf"].map { "\(prefix).num.\($0)" }))
    }
    static func scientific(_ prefix: String) -> Item {
        .menu(title: "Scientific", symbol: "x.squareroot", cmds(["absolute", "power", "sqrt", "exp"].map { "\(prefix).num.\($0)" })
              + [.submenu("Logarithm", cmds(["log10", "ln"].map { "\(prefix).num.\($0)" })), .command("\(prefix).num.factorial")])
    }
    static func trigonometry(_ prefix: String) -> Item {
        .menu(title: "Trigonometry", symbol: "function", cmds(["sin", "cos", "tan", "asin", "acos", "atan"].map { "\(prefix).num.\($0)" }))
    }
    static func rounding(_ prefix: String) -> Item {
        .menu(title: "Rounding", symbol: "arrow.up.and.down.circle", cmds(["roundUp", "roundDown", "round"].map { "\(prefix).num.\($0)" }))
    }
    static func information(_ prefix: String) -> Item {
        .menu(title: "Information", symbol: "info.circle", cmds(["isEven", "isOdd", "sign"].map { "\(prefix).num.\($0)" }))
    }
    static func date(_ prefix: String) -> Item {
        func d(_ ops: [String]) -> [Entry] { cmds(ops.map { "\(prefix).date.\($0)" }) }
        var entries = d(["age", "dateOnly"]) + [
            .submenu("Year", d(["year", "startOfYear", "endOfYear"])),
            .submenu("Month", d(["month", "startOfMonth", "endOfMonth", "daysInMonth", "monthName"])),
            .submenu("Quarter", d(["quarter", "startOfQuarter", "endOfQuarter"])),
            .submenu("Week", d(["weekOfYear", "weekOfMonth", "startOfWeek", "endOfWeek"])),
            .submenu("Day", d(["day", "dayOfWeek", "dayOfYear", "startOfDay", "endOfDay", "dayName"])),
        ]
        if prefix == "pq" { entries += [.divider, .command("pq.earliest"), .command("pq.latest")] }
        return .menu(title: "Date", symbol: "calendar", entries)
    }
    static func time(_ prefix: String) -> Item {
        .menu(title: "Time", symbol: "clock", cmds(["timeOnly", "hour", "startOfHour", "endOfHour", "minute", "second"].map { "\(prefix).date.\($0)" }))
    }
    static func duration(_ prefix: String) -> Item {
        .menu(title: "Duration", symbol: "timer", cmds(["durationDays", "durationHours", "durationMinutes", "durationSeconds", "totalDays", "totalHours", "totalMinutes", "totalSeconds"].map { "\(prefix).date.\($0)" }))
    }
    static let ai = Group(title: "AI Insights", items: [.button("pq.ai.text"), .button("pq.ai.vision"), .button("pq.ai.ml")])

    static let tabs: [Tab] = [
        Tab(title: "Home", groups: [
            Group(title: "Close", items: [.menu(title: "Close & Apply", symbol: "checkmark.rectangle", cmds(["pq.closeApply", "pq.apply", "pq.close"]))]),
            Group(title: "New Query", items: [
                .button("pq.newSource"),
                .menu(title: "Recent Sources", symbol: "clock", cmds(["pq.recentSources"])),
                .button("pq.enterData"), .button("pq.blankQuery"),
            ]),
            Group(title: "Data Sources", items: [.button("pq.dataSourceSettings")]),
            Group(title: "Parameters", items: [.menu(title: "Manage Parameters", symbol: "slider.horizontal.3", cmds(["pq.manageParameters", "pq.newParameter"]))]),
            Group(title: "Query", items: [
                .menu(title: "Refresh Preview", symbol: "arrow.clockwise", cmds(["pq.refreshPreview", "pq.refreshAll"])),
                .button("pq.properties"), .button("pq.advancedEditor"),
                .menu(title: "Manage", symbol: "square.stack", cmds(["pq.deleteQuery", "pq.duplicateQuery", "pq.referenceQuery"])),
            ]),
            Group(title: "Manage Columns", items: [
                .menu(title: "Choose Columns", symbol: "checklist", cmds(["pq.chooseColumns", "pq.goToColumn"])),
                .menu(title: "Remove Columns", symbol: "minus.square", cmds(["pq.removeColumns", "pq.removeOtherColumns"])),
            ]),
            Group(title: "Reduce Rows", items: [
                .menu(title: "Keep Rows", symbol: "line.3.horizontal", cmds(["pq.keepTopRows", "pq.keepBottomRows", "pq.keepRange", "pq.keepDuplicates", "pq.keepErrors"])),
                .menu(title: "Remove Rows", symbol: "line.3.horizontal.decrease", cmds(["pq.removeTopRows", "pq.removeBottomRows", "pq.removeAlternateRows", "pq.removeDuplicates", "pq.removeBlankRows", "pq.removeErrors"])),
            ]),
            Group(title: "Sort", items: [.button("pq.sortAscending"), .button("pq.sortDescending")]),
            Group(title: "Transform", items: [split, .button("pq.groupBy"), dataType, headers, .button("pq.replaceValues")]),
            Group(title: "Combine", items: [
                .menu(title: "Merge Queries", symbol: "arrow.triangle.merge", cmds(["pq.mergeQueries", "pq.mergeQueriesNew"])),
                .menu(title: "Append Queries", symbol: "rectangle.stack.badge.plus", cmds(["pq.appendQueries", "pq.appendQueriesNew"])),
                .button("pq.combineFiles"),
            ]),
            ai,
        ]),
        Tab(title: "Transform", groups: [
            Group(title: "Table", items: [.button("pq.groupBy"), headers, .button("pq.transpose"), .button("pq.reverseRows"), .button("pq.countRows")]),
            Group(title: "Any Column", items: [
                dataType, .button("pq.detectType"), .button("pq.renameColumn"),
                .menu(title: "Replace Values", symbol: "arrow.left.arrow.right", cmds(["pq.replaceValues", "pq.replaceErrors"])),
                .menu(title: "Fill", symbol: "arrow.down.to.line.compact", cmds(["pq.fillDown", "pq.fillUp"])),
                .button("pq.pivot"),
                .menu(title: "Move", symbol: "arrow.left.arrow.right.square", cmds(["pq.moveLeft", "pq.moveRight", "pq.moveToBeginning", "pq.moveToEnd"])),
                .menu(title: "Unpivot Columns", symbol: "arrow.turn.left.down", cmds(["pq.unpivot", "pq.unpivotOther", "pq.unpivotSelected"])),
                .button("pq.convertToList"),
            ]),
            Group(title: "Text Column", items: [split, format("pq"), .button("pq.mergeColumns"), extract("pq"), parse("pq")]),
            Group(title: "Number Column", items: [statistics("pq"), standard("pq"), scientific("pq"), trigonometry("pq"), rounding("pq"), information("pq")]),
            Group(title: "Date & Time Column", items: [date("pq"), time("pq"), duration("pq")]),
            Group(title: "Structured Column", items: [.button("pq.expand"), .button("pq.aggregate"), .button("pq.extractValues")]),
            Group(title: "Scripts", items: [.button("pq.runR"), .button("pq.runPython")]),
        ]),
        Tab(title: "Add Column", groups: [
            Group(title: "General", items: [
                .menu(title: "Column From Examples", symbol: "wand.and.rays", cmds(["pq.add.examples", "pq.add.examplesSelection"])),
                .button("pq.add.custom"), .button("pq.add.invoke"), .button("pq.add.conditional"),
                .menu(title: "Index Column", symbol: "list.number", cmds(["pq.add.index0", "pq.add.index1", "pq.add.indexCustom"])),
                .button("pq.add.duplicate"),
            ]),
            Group(title: "From Text", items: [format("pq.add"), .button("pq.add.mergeColumns"), extract("pq.add"), parse("pq.add")]),
            Group(title: "From Number", items: [statistics("pq.add"), standard("pq.add"), scientific("pq.add"), trigonometry("pq.add"), rounding("pq.add"), information("pq.add")]),
            Group(title: "From Date & Time", items: [date("pq.add"), time("pq.add"), duration("pq.add")]),
            ai,
        ]),
        Tab(title: "View", groups: [
            Group(title: "Layout", items: [.button("pq.view.querySettings"), .button("pq.view.formulaBar")]),
            Group(title: "Data Preview", items: [
                .button("pq.view.monospaced"), .button("pq.view.whitespace"), .button("pq.view.quality"),
                .button("pq.view.distribution"), .button("pq.view.profile"), .button("pq.view.wholeDataset"),
            ]),
            Group(title: "Columns", items: [.button("pq.goToColumn")]),
            Group(title: "Advanced", items: [.button("pq.advancedEditor")]),
            Group(title: "Dependencies", items: [.button("pq.view.dependencies")]),
        ]),
        Tab(title: "Tools", groups: [
            Group(title: "Diagnostics", items: [.button("pq.tools.diagnoseStep"), .button("pq.tools.startDiagnostics"), .button("pq.tools.stopDiagnostics")]),
            Group(title: "Folding", items: [.button("pq.tools.nativeQuery")]),
        ]),
    ]

    /// Every command id the ribbon references (for checking that each resolves to a command).
    static var referencedIDs: [String] {
        func ids(_ e: [Entry]) -> [String] {
            e.flatMap { entry -> [String] in
                switch entry {
                case .command(let id): return [id]
                case .divider: return []
                case .submenu(_, let inner): return ids(inner)
                }
            }
        }
        return tabs.flatMap { $0.groups.flatMap { $0.items.flatMap { item -> [String] in
            switch item {
            case .button(let id): return [id]
            case .menu(_, _, let entries): return ids(entries)
            }
        } } }
    }
}

// MARK: - View

/// The editor's ribbon: a tab strip over one row of groups, scrolling sideways when the window is narrow.
struct EditorRibbonView: View {
    @ObservedObject var session: QueryEditorSession
    @State private var tab = "Home"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.m) {
                ForEach(EditorRibbonLayout.tabs) { t in
                    Button { tab = t.title } label: {
                        Text(t.title).font(tab == t.title ? Design.Typeface.bodyStrong : Design.Typeface.body)
                            .foregroundStyle(tab == t.title ? Color.primary : Color.secondary)
                            .padding(.vertical, Design.Space.xs)
                            .overlay(alignment: .bottom) {
                                if tab == t.title { Rectangle().fill(Color.accentColor).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                IconButton("arrow.uturn.backward", help: session.undoName.map { "Undo \($0)" } ?? "Nothing to undo") { session.undo() }
                    .disabled(session.undoName == nil)
                    .keyboardShortcut("z", modifiers: .command)
                IconButton("arrow.uturn.forward", help: session.redoName.map { "Redo \($0)" } ?? "Nothing to redo") { session.redo() }
                    .disabled(session.redoName == nil)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.xs)
            Hairline()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array((EditorRibbonLayout.tabs.first { $0.title == tab }?.groups ?? []).enumerated()), id: \.offset) { _, group in
                        groupView(group)
                        Hairline(vertical: true).padding(.vertical, Design.Space.xs)
                    }
                }
                .padding(.horizontal, Design.Space.xs)
            }
            .frame(height: 78)
        }
        .background(Design.Palette.surface)
    }

    private func groupView(_ group: EditorRibbonLayout.Group) -> some View {
        VStack(spacing: Design.Space.xxs) {
            HStack(alignment: .top, spacing: Design.Space.xxs) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in itemView(item) }
            }
            Spacer(minLength: 0)
            Text(group.title).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, Design.Space.xs).padding(.vertical, Design.Space.xs)
    }

    @ViewBuilder
    private func itemView(_ item: EditorRibbonLayout.Item) -> some View {
        switch item {
        case .button(let id):
            if let command = EditorCommands.command(id) {
                let blocker = command.blocker(session)
                Button { command.run(session) } label: { face(command.title, command.symbol, isOn: command.isOn?(session) ?? false) }
                    .buttonStyle(.plain)
                    .disabled(blocker != nil)
                    .opacity(blocker == nil ? 1 : 0.4)
                    .help(blocker ?? command.title)
            }
        case .menu(let title, let symbol, let entries):
            Menu { EditorMenuEntries(session: session, entries: entries) } label: { face(title, symbol, isOn: false, menu: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(title)
        }
    }

    private func face(_ title: String, _ symbol: String, isOn: Bool, menu: Bool = false) -> some View {
        VStack(spacing: Design.Space.xxs) {
            Image(systemName: symbol).font(.system(size: 17, weight: .light))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(height: 22)
            (Text(title.replacingOccurrences(of: "…", with: "")) + (menu ? Text(" ") + Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .semibold)) : Text("")))
                .font(.system(size: 10)).multilineTextAlignment(.center).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 64, alignment: .top)
        .padding(.vertical, Design.Space.xxs)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(isOn ? Color.accentColor.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
    }
}

/// Menu items for ribbon menus, header menus and context menus.
struct EditorMenuEntries: View {
    @ObservedObject var session: QueryEditorSession
    let entries: [EditorRibbonLayout.Entry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .divider: Divider()
            case .submenu(let title, let inner): Menu(title) { EditorMenuEntries(session: session, entries: inner) }
            case .command(let id):
                if let command = EditorCommands.command(id) {
                    let blocker = command.blocker(session)
                    if let on = command.isOn?(session) {
                        Toggle(command.title, isOn: Binding(get: { on }, set: { _ in command.run(session) })).disabled(blocker != nil)
                    } else {
                        Button(command.title) { command.run(session) }.disabled(blocker != nil).help(blocker ?? "")
                    }
                }
            }
        }
    }
}
