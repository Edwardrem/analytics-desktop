import SwiftUI
import FacetCore
import FacetDesign

/// Conditional formatting rules for one visual: background/font colour, data bars, icons,
/// data point colour, web URL and image columns, and dynamic titles.
struct ConditionalFormatsSection: View {
    let spec: VisualSpec
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        FieldPaneSection("Conditional formatting", count: spec.conditionalFormats.count,
                         expanded: !spec.conditionalFormats.isEmpty) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                ForEach(spec.conditionalFormats) { rule in
                    RuleRow(spec: spec, rule: rule)
                }
                Menu {
                    ForEach(BuildLogic.conditionalTargets(for: spec.type), id: \.self) { target in
                        Button(BuildLogic.title(target)) { add(target) }
                    }
                } label: {
                    Label("Add a rule", systemImage: "plus.circle").font(Design.Typeface.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func add(_ target: ConditionalFormat.Target) {
        store.updateVisual(spec.id, name: "Add Conditional Format") { v in
            guard !v.conditionalFormats.contains(where: { $0.target == target }) else { return }
            v.conditionalFormats.append(Self.newRule(target, for: v))
        }
    }

    /// A rule for `target` with the defaults the pane starts from: the target's usual mode,
    /// applied to the visual's first field and driven by its first aggregate.
    static func newRule(_ target: ConditionalFormat.Target, for v: VisualSpec) -> ConditionalFormat {
        var rule = ConditionalFormat(target: target)
        rule.mode = mode(for: target)
        rule.appliesToKey = v.allFields.first?.key
        rule.basedOn = v.allFields.first { $0.isAggregate } ?? v.allFields.first
        return rule
    }

    private static func mode(for target: ConditionalFormat.Target) -> ConditionalFormat.Mode {
        switch target {
        case .background, .fontColor, .dataBars, .dataPointColor, .icons: return .gradient
        case .webURL, .image, .title: return .fieldValue
        case .columnWidth: return .rules
        }
    }

    // MARK: One rule

    /// One rule with its editor. The Format pane's fx buttons show the same row, opened.
    struct RuleRow: View {
        let spec: VisualSpec
        let rule: ConditionalFormat
        @EnvironmentObject var store: DocumentStore
        @State private var expanded: Bool

        init(spec: VisualSpec, rule: ConditionalFormat, expanded: Bool = false) {
            self.spec = spec; self.rule = rule; self._expanded = State(initialValue: expanded)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                HStack(spacing: Design.Space.xs) {
                    Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                        HStack(spacing: Design.Space.xs) {
                            Image(systemName: BuildLogic.symbol(rule.target)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(BuildLogic.title(rule.target)).font(Design.Typeface.body).lineLimit(1)
                            Text(modeName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button("Remove", role: .destructive) {
                            store.updateVisual(spec.id, name: "Remove Conditional Format") {
                                $0.conditionalFormats.removeAll { $0.id == rule.id }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if expanded {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        Picker("Mode", selection: mode) {
                            Text("Gradient").tag(ConditionalFormat.Mode.gradient)
                            Text("Rules").tag(ConditionalFormat.Mode.rules)
                            Text("Field value").tag(ConditionalFormat.Mode.fieldValue)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if rule.mode == .fieldValue {
                            Picker("Based on field", selection: basedOn) {
                                ForEach(fields, id: \.key) { f in Text(f.caption).tag(f.key) }
                            }
                            .labelsHidden()
                        } else if rule.mode == .gradient {
                            HStack(spacing: Design.Space.s) {
                                CommitColorWell(hex: rule.minColor) { c in update { $0.minColor = c } }
                                if let mid = rule.midColor {
                                    CommitColorWell(hex: mid) { c in update { $0.midColor = c } }
                                } else {
                                    Button("Add centre colour") { update { $0.midColor = "#7AB8FF" } }
                                        .buttonStyle(.link).font(Design.Typeface.caption)
                                }
                                CommitColorWell(hex: rule.maxColor) { c in update { $0.maxColor = c } }
                            }
                        } else {
                            ForEach(rule.rules.indices, id: \.self) { i in
                                HStack(spacing: Design.Space.xs) {
                                    Text(rule.rules[i].op.displayName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                                    CommitNumberField(value: rule.rules[i].value, width: 64) { v in
                                        update { $0.rules[i].value = v }
                                    }
                                    CommitColorWell(hex: rule.rules[i].color) { c in update { $0.rules[i].color = c } }
                                }
                            }
                            Button("Add range") { update { $0.rules.append(ConditionalFormat.Rule()) } }
                                .buttonStyle(.link).font(Design.Typeface.caption)
                        }
                    }
                    .padding(Design.Space.s)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Design.Palette.fill))
                }
                Hairline()
            }
            .padding(.vertical, Design.Space.xs)
        }

        private var fields: [FieldRef] { spec.allFields }
        private var modeName: String {
            switch rule.mode {
            case .gradient: return "Gradient"
            case .rules: return "Rules"
            case .fieldValue: return "By field"
            }
        }
        private var mode: Binding<ConditionalFormat.Mode> {
            Binding(get: { rule.mode }, set: { m in update { $0.mode = m } })
        }
        private var basedOn: Binding<String> {
            Binding(get: { rule.basedOn?.key ?? "" }, set: { key in
                update { $0.basedOn = fields.first { $0.key == key } }
            })
        }
        private func update(_ body: (inout ConditionalFormat) -> Void) {
            store.updateVisual(spec.id, name: "Change Conditional Format") { v in
                if let i = v.conditionalFormats.firstIndex(where: { $0.id == rule.id }) { body(&v.conditionalFormats[i]) }
            }
        }
    }
}
