import SwiftUI
import FacetCore

/// Realistic sample spec + data for every component type — for previews, galleries and snapshot checks.
public enum ComponentGallery {
    public static func samples() -> [(spec: VisualSpec, data: VisualData)] {
        CmpTableFamily.samples() + CmpCardFamily.samples() + CmpSlicerFamily.samples()
            + CmpMapFamily.samples() + CmpPageFamily.samples()
    }
}
