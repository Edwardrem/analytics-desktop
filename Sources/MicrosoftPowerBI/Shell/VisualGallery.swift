import SwiftUI
import FacetCore
import FacetDesign

/// Searchable grid of every visual type.
struct VisualGallery: View {
    let choose: (VisualType) -> Void
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            TextField("Search visuals", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    ForEach(VisualCatalog.groups, id: \.name) { group in
                        let types = group.types.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
                        if !types.isEmpty {
                            VStack(alignment: .leading, spacing: Design.Space.s) {
                                SectionLabel(group.name)
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                                    ForEach(types, id: \.self) { t in GalleryTile(type: t) { choose(t) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Design.Space.l)
        .frame(width: 440, height: 520)
    }
}

private struct GalleryTile: View {
    let type: VisualType
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: VisualCatalog.symbol(for: type)).font(.system(size: 18, weight: .light)).frame(height: 22)
                Text(type.displayName.replacingOccurrences(of: " chart", with: "")).font(.system(size: 9.5)).lineLimit(2)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 62)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Design.Palette.fillStrong : Design.Palette.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(type.displayName)
    }
}
