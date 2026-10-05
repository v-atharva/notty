import Foundation

/// A platform-neutral sRGB ink colour.
public struct EditorInkColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func unit(_ value: Double) -> Double { value.isFinite ? max(0, min(value, 1)) : 0 }
        self.red = unit(red)
        self.green = unit(green)
        self.blue = unit(blue)
        self.alpha = unit(alpha)
    }

    init?(components: [Double]) {
        guard components.count == 4 else { return nil }
        self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    var components: [Double] { [red, green, blue, alpha] }

    /// The colour rounded to 8-bit channels, the precision of the system colour picker,
    /// so the same visible colour is recognised however it was produced.
    public var quantized: EditorInkColor {
        func step(_ channel: Double) -> Double { (channel * 255).rounded() / 255 }
        return EditorInkColor(red: step(red), green: step(green), blue: step(blue), alpha: step(alpha))
    }

    /// WCAG relative luminance of the opaque colour.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio. The catalog's contract is that every ink reaches 3:1 on the paper.
    public func contrastRatio(against other: EditorInkColor) -> Double {
        let (lighter, darker) = relativeLuminance > other.relativeLuminance
            ? (relativeLuminance, other.relativeLuminance)
            : (other.relativeLuminance, relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Native ink families the toolbar offers. Each maps to a PencilKit ink type in the app.
/// Raw values are stored, so they must never change.
public enum EditorInkFamily: String, CaseIterable, Sendable {
    case pen = "pen"
    case monoline = "monoline"
    case fountainPen = "fountainPen"
    case reed = "reed"
    case pencil = "pencil"
    case marker = "marker"
    case crayon = "crayon"
    case watercolor = "watercolor"
}

/// Width choices expressed as a position inside each ink's valid range, so "medium"
/// reads as medium for a fine pen and a broad marker alike. Raw values are stored,
/// so they must never change.
public enum EditorWidthStep: Int, CaseIterable, Sendable {
    case fine = 0
    case medium = 1
    case bold = 2

    var fraction: Double {
        switch self {
        case .fine: 0.12
        case .medium: 0.35
        case .bold: 0.7
        }
    }
}

public struct EditorInkPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let family: EditorInkFamily
    public let color: EditorInkColor
    public let widthStep: EditorWidthStep
}

/// The proposed retro presets and quick swatches. Values are a starting point for
/// review on the device, not approved final colours.
public enum EditorInkCatalog {
    public static let presets: [EditorInkPreset] = [
        EditorInkPreset(id: "sepia-fountain", name: "Sepia fountain pen", family: .fountainPen, color: sepia, widthStep: .medium),
        EditorInkPreset(id: "charcoal-monoline", name: "Charcoal monoline", family: .monoline, color: charcoal, widthStep: .fine),
        EditorInkPreset(id: "graphite-pencil", name: "Graphite pencil", family: .pencil, color: graphite, widthStep: .medium),
        EditorInkPreset(id: "ochre-marker", name: "Muted ochre marker", family: .marker, color: ochre, widthStep: .bold),
    ]

    public static let swatches: [EditorInkColor] = [
        charcoal,
        sepia,
        EditorInkColor(red: 0.62, green: 0.30, blue: 0.20),
        EditorInkColor(red: 0.42, green: 0.50, blue: 0.38),
        EditorInkColor(red: 0.36, green: 0.45, blue: 0.56),
        EditorInkColor(red: 0.45, green: 0.31, blue: 0.40),
        ochre,
    ]

    public static func width(for step: EditorWidthStep, in range: ClosedRange<Double>) -> Double {
        range.lowerBound + step.fraction * (range.upperBound - range.lowerBound)
    }

    private static let charcoal = EditorInkColor(red: 0.20, green: 0.19, blue: 0.18)
    private static let sepia = EditorInkColor(red: 0.44, green: 0.29, blue: 0.17)
    private static let graphite = EditorInkColor(red: 0.33, green: 0.33, blue: 0.33)
    private static let ochre = EditorInkColor(red: 0.60, green: 0.47, blue: 0.20)
}
