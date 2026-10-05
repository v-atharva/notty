import PencilKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Object erasing removes whole strokes; pixel erasing removes only what it touches.
/// Raw values are stored, so they must never change.
public enum EditorEraserMode: String, Hashable, Sendable {
    case vector = "vector"
    case bitmap = "bitmap"

    var nativeType: PKEraserTool.EraserType {
        switch self {
        case .vector: .vector
        case .bitmap: .bitmap
        }
    }
}

/// Mirrors the system's Apple Pencil tap and squeeze settings (UIPencilPreferredAction),
/// so the mapping can be tested without UIKit.
public enum EditorPencilTapPreference: Sendable {
    case ignore
    case switchEraser
    case switchPrevious
    case showColorPalette
    case showInkAttributes
    case showContextualPalette
    /// The system runs the user's shortcut itself; the app takes no action.
    case runSystemShortcut
}

public enum EditorToolKind: Hashable, Sendable {
    case ink(EditorInkFamily)
    case eraser(EditorEraserMode)
    case lasso
}

/// The app-owned drawing tool selection. It only produces native PencilKit tools;
/// ink rendering, pressure and smoothing stay with PencilKit.
///
/// Equality covers everything that is stored, not the in-session history the Pencil
/// gestures use, so a restored state equals the one that was saved.
public struct EditorToolState: Equatable, Sendable {
    public static let standard = EditorToolState(
        kind: .ink(.pen), color: EditorInkCatalog.swatches[0], widthStep: .fine, isRulerActive: false
    )

    public private(set) var kind: EditorToolKind
    public var color: EditorInkColor {
        didSet { if color != oldValue { activePresetID = nil } }
    }
    public var widthStep: EditorWidthStep {
        didSet { if widthStep != oldValue { activePresetID = nil } }
    }
    /// The ruler is a canvas overlay that works with any ink, not a tool of its own.
    public var isRulerActive: Bool
    /// The preset matching the current ink. It stays while the eraser or lasso is in use,
    /// since returning to that ink restores the same values.
    public private(set) var activePresetID: String?
    private var lastInkFamily: EditorInkFamily
    private var lastEraserMode: EditorEraserMode = .vector
    /// The last tool different from the current one, for the Pencil "previous tool" gesture.
    private var previousKind: EditorToolKind?
    /// The ink or lasso in use when the eraser was picked, for the Pencil "switch eraser" gesture.
    private var kindBeforeEraser: EditorToolKind?

    public init(kind: EditorToolKind, color: EditorInkColor, widthStep: EditorWidthStep, isRulerActive: Bool) {
        self.kind = kind
        self.color = color
        self.widthStep = widthStep
        self.isRulerActive = isRulerActive
        if case let .ink(family) = kind { lastInkFamily = family } else { lastInkFamily = .pen }
    }

    public var inkFamily: EditorInkFamily? {
        if case let .ink(family) = kind { return family }
        return nil
    }

    public mutating func select(_ kind: EditorToolKind) {
        switch kind {
        case let .ink(family):
            if family != lastInkFamily { activePresetID = nil }
            lastInkFamily = family
        case let .eraser(mode):
            lastEraserMode = mode
            if !isErasing { kindBeforeEraser = self.kind }
        case .lasso:
            break
        }
        if kind != self.kind { previousKind = self.kind }
        self.kind = kind
    }

    private var isErasing: Bool {
        if case .eraser = kind { return true }
        return false
    }

    /// Selects the eraser in the mode last used; already erasing, it stays on the eraser.
    public mutating func selectEraser() {
        guard !isErasing else { return }
        select(.eraser(lastEraserMode))
    }

    /// Returns from the eraser or lasso to the ink in use before it.
    public mutating func selectPreviousInk() {
        select(.ink(lastInkFamily))
    }

    /// Responds to an Apple Pencil double-tap or squeeze according to the user's system setting.
    /// Returns true when the toolbar should be revealed so the user can pick from it.
    /// The ruler is never changed: it is an overlay the user positions deliberately.
    public mutating func handlePencilDoubleTap(_ preference: EditorPencilTapPreference) -> Bool {
        switch preference {
        case .ignore, .runSystemShortcut:
            return false
        case .switchEraser:
            // Like Apple's own tools, this toggles between the eraser and the tool in use
            // before it; a restored eraser has no such tool and returns to the last ink.
            if isErasing { select(kindBeforeEraser ?? .ink(lastInkFamily)) } else { selectEraser() }
            return false
        case .switchPrevious:
            if let previousKind { select(previousKind) }
            return false
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            // Apple's palette is not shown, so the app toolbar is the place to choose.
            return true
        }
    }

    public mutating func apply(_ preset: EditorInkPreset) {
        select(.ink(preset.family))
        color = preset.color
        widthStep = preset.widthStep
        activePresetID = preset.id
    }

    /// Stored separately from notebook content, so a damaged value only resets the tool.
    public func encoded() -> Data {
        var stored = Stored(
            version: Self.storageVersion, kind: "", family: nil, eraser: nil,
            color: [color.red, color.green, color.blue, color.alpha], width: widthStep.rawValue,
            ruler: isRulerActive, preset: activePresetID,
            lastInk: lastInkFamily.rawValue, lastEraser: lastEraserMode.rawValue
        )
        switch kind {
        case let .ink(family):
            stored.kind = "ink"
            stored.family = family.rawValue
        case let .eraser(mode):
            stored.kind = "eraser"
            stored.eraser = mode.rawValue
        case .lasso:
            stored.kind = "lasso"
        }
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// Restores a stored tool. Missing, corrupt, unknown-version or unknown-ink data
    /// yields `standard`; a preset is claimed only while its values still match.
    public static func decode(_ data: Data?) -> EditorToolState {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == storageVersion,
              let color = EditorInkColor(components: stored.color),
              let widthStep = EditorWidthStep(rawValue: stored.width) else { return .standard }
        let kind: EditorToolKind
        switch stored.kind {
        case "ink":
            guard let family = stored.family.flatMap(EditorInkFamily.init(rawValue:)) else { return .standard }
            kind = .ink(family)
        case "eraser":
            guard let mode = stored.eraser.flatMap(EditorEraserMode.init(rawValue:)) else { return .standard }
            kind = .eraser(mode)
        case "lasso":
            kind = .lasso
        default:
            return .standard
        }
        var state = EditorToolState(kind: kind, color: color, widthStep: widthStep, isRulerActive: stored.ruler)
        if let lastInk = stored.lastInk.flatMap(EditorInkFamily.init(rawValue:)), state.inkFamily == nil {
            state.lastInkFamily = lastInk
        }
        if let lastEraser = stored.lastEraser.flatMap(EditorEraserMode.init(rawValue:)) {
            state.lastEraserMode = lastEraser
        }
        if let id = stored.preset,
           let preset = EditorInkCatalog.presets.first(where: { $0.id == id }),
           preset.family == state.lastInkFamily, color == preset.color, widthStep == preset.widthStep {
            state.activePresetID = id
        }
        return state
    }

    public static func == (lhs: EditorToolState, rhs: EditorToolState) -> Bool {
        lhs.kind == rhs.kind
            && lhs.color == rhs.color
            && lhs.widthStep == rhs.widthStep
            && lhs.isRulerActive == rhs.isRulerActive
            && lhs.activePresetID == rhs.activePresetID
            && lhs.lastInkFamily == rhs.lastInkFamily
            && lhs.lastEraserMode == rhs.lastEraserMode
    }

    private static let storageVersion = 1

    private struct Stored: Codable {
        let version: Int
        var kind: String
        var family: String?
        var eraser: String?
        let color: [Double]
        let width: Int
        let ruler: Bool
        let preset: String?
        let lastInk: String?
        let lastEraser: String?
    }

    public var nativeTool: PKTool {
        switch kind {
        case let .ink(family):
            let range = family.inkType.validWidthRange
            let width = EditorInkCatalog.width(
                for: widthStep, in: Double(range.lowerBound)...Double(range.upperBound)
            )
            return PKInkingTool(family.inkType, color: color.platformColor, width: CGFloat(width))
        case let .eraser(mode):
            return PKEraserTool(mode.nativeType)
        case .lasso:
            return PKLassoTool()
        }
    }
}

public extension EditorInkFamily {
    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .monoline: .monoline
        case .fountainPen: .fountainPen
        case .reed: .reed
        case .pencil: .pencil
        case .marker: .marker
        case .crayon: .crayon
        case .watercolor: .watercolor
        }
    }
}

public extension EditorInkColor {
    /// The one conversion to a platform colour, shared by the canvas ink and the toolbar
    /// so the two can never drift apart.
    #if canImport(UIKit)
    var platformColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    #else
    var platformColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    #endif
}
