import CoreGraphics
import Foundation

/// Fixed positions along the top edge of the editor. Raw values are stored, so they
/// must never change.
public enum EditorToolbarDock: String, CaseIterable, Sendable {
    case topLeading = "topLeading"
    case topCenter = "topCenter"
    case topTrailing = "topTrailing"
}

public enum EditorToolbarPlacement: Equatable, Sendable {
    case docked(EditorToolbarDock)
    /// Toolbar centre as fractions of the usable bounds, so rotation and window
    /// resizing keep it in the same relative place.
    case floating(CGPoint)
}

/// Pure frame calculations for the editor toolbar, independent of any view.
public enum EditorToolbarLayout {
    public static let margin: CGFloat = 12
    /// How close a drag must end to a dock's position to snap into it.
    public static let snapDistance: CGFloat = 56

    public static func frame(for placement: EditorToolbarPlacement, size: CGSize, in usable: CGRect) -> CGRect {
        let origin: CGPoint
        switch placement {
        case let .docked(dock):
            let y = usable.minY + margin
            switch dock {
            case .topLeading: origin = CGPoint(x: usable.minX + margin, y: y)
            case .topCenter: origin = CGPoint(x: usable.midX - size.width / 2, y: y)
            case .topTrailing: origin = CGPoint(x: usable.maxX - margin - size.width, y: y)
            }
        case let .floating(fraction):
            let center = CGPoint(
                x: usable.minX + clampUnit(fraction.x) * usable.width,
                y: usable.minY + clampUnit(fraction.y) * usable.height
            )
            origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        }
        return clamped(CGRect(origin: origin, size: size), in: usable)
    }

    /// Resolves where a toolbar dragged to `center` comes to rest, for a toolbar that keeps
    /// its size when docked.
    public static func placement(
        forDragEndingAt center: CGPoint, size: CGSize, in usable: CGRect, snapDistance: CGFloat = snapDistance
    ) -> EditorToolbarPlacement {
        placement(
            forDragEnding: CGRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height
            ),
            dockSize: size, in: usable, snapDistance: snapDistance
        )
    }

    /// Resolves where a toolbar dragged to `frame` comes to rest: the nearest dock within
    /// `snapDistance`, otherwise a floating position at the clamped location.
    ///
    /// Each dock is measured at the point it aligns, the middle of the leading edge, the centre
    /// or the middle of the trailing edge, against the frame a toolbar of `dockSize` takes there.
    /// A frame of the docked size therefore snaps exactly as its centre would, and a smaller one,
    /// such as a collapsed handle, snaps where it sits at that dock's end of the slot. Docks at the same
    /// distance, as when the toolbar fills the width and every dock has one frame, resolve to
    /// `current` when it is among them, then to the standard centre dock, so a drop in place
    /// changes nothing.
    public static func placement(
        forDragEnding frame: CGRect, dockSize: CGSize, in usable: CGRect,
        current: EditorToolbarPlacement? = nil, snapDistance: CGFloat = snapDistance
    ) -> EditorToolbarPlacement {
        let distances = EditorToolbarDock.allCases.map { dock in
            let slot = self.frame(for: .docked(dock), size: dockSize, in: usable)
            return (dock, distance(anchor(of: frame, for: dock), anchor(of: slot, for: dock)))
        }
        if let nearest = distances.map(\.1).min(), nearest <= snapDistance {
            let tied = distances.filter { $0.1 - nearest < 0.5 }.map(\.0)
            let preferred = [current.flatMap(dock(of:)), .topCenter].compactMap { $0 }
            return .docked(preferred.first(where: tied.contains) ?? tied[0])
        }

        let rest = clamped(frame, in: usable)
        guard usable.width > 0, usable.height > 0 else { return .docked(.topCenter) }
        return .floating(CGPoint(
            x: clampUnit((rest.midX - usable.minX) / usable.width),
            y: clampUnit((rest.midY - usable.minY) / usable.height)
        ))
    }

    private static func anchor(of frame: CGRect, for dock: EditorToolbarDock) -> CGPoint {
        switch dock {
        case .topLeading: CGPoint(x: frame.minX, y: frame.midY)
        case .topCenter: CGPoint(x: frame.midX, y: frame.midY)
        case .topTrailing: CGPoint(x: frame.maxX, y: frame.midY)
        }
    }

    private static func dock(of placement: EditorToolbarPlacement) -> EditorToolbarDock? {
        if case let .docked(dock) = placement { return dock }
        return nil
    }

    /// Keeps the frame inside the margins. When it cannot fit, the leading and top
    /// edges win so the first tools stay reachable.
    static func clamped(_ frame: CGRect, in usable: CGRect) -> CGRect {
        func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            guard value.isFinite else { return lower }
            return max(lower, min(value, upper))
        }
        let x = clamp(frame.minX, lower: usable.minX + margin, upper: usable.maxX - margin - frame.width)
        let y = clamp(frame.minY, lower: usable.minY + margin, upper: usable.maxY - margin - frame.height)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, min(value, 1)) : 0.5
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Toolbar presentation preferences. Stored apart from notebook content and history,
/// so a damaged preference can never prevent a notebook from opening.
///
/// Every value satisfies the same rules however it was made: a floating position is
/// finite and inside the unit square, only a floating toolbar collapses, and at most
/// `maximumCustomSwatches` custom colours are kept.
public struct EditorToolbarPreferences: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumCustomSwatches = 8
    public static let standard = EditorToolbarPreferences(placement: standardPlacement, isCollapsed: false, customSwatches: [])
    private static let standardPlacement = EditorToolbarPlacement.docked(.topCenter)

    public private(set) var placement: EditorToolbarPlacement
    public private(set) var isCollapsed: Bool
    /// Newest first.
    public private(set) var customSwatches: [EditorInkColor]
    public private(set) var chromeMode: EditorChromeMode

    /// A floating position that is not finite falls back to the standard dock.
    public init(
        placement: EditorToolbarPlacement, isCollapsed: Bool, customSwatches: [EditorInkColor],
        chromeMode: EditorChromeMode = .focus
    ) {
        self.placement = Self.sanitized(placement)
        self.isCollapsed = false
        self.customSwatches = []
        self.chromeMode = chromeMode
        setCollapsed(isCollapsed)
        setCustomSwatches(customSwatches)
    }

    /// Moves the toolbar and shows it in full.
    public mutating func place(_ placement: EditorToolbarPlacement) {
        self.placement = Self.sanitized(placement)
        isCollapsed = false
    }

    /// Collapses or expands a floating toolbar; a docked toolbar always stays expanded.
    public mutating func setCollapsed(_ collapsed: Bool) {
        if case .floating = placement { isCollapsed = collapsed } else { isCollapsed = false }
    }

    public mutating func setChromeMode(_ mode: EditorChromeMode) {
        chromeMode = mode
    }

    /// Adds a picked colour at the front of the custom swatches, rounded to 8-bit channels.
    /// A colour that matches a quick swatch is not added; one that matches a custom swatch
    /// moves to the front instead of repeating.
    public mutating func addCustomSwatch(_ color: EditorInkColor) {
        let picked = color.quantized
        guard !EditorInkCatalog.swatches.contains(where: { $0.quantized == picked }) else { return }
        setCustomSwatches([picked] + customSwatches.filter { $0.quantized != picked })
    }

    private mutating func setCustomSwatches(_ swatches: [EditorInkColor]) {
        customSwatches = Array(swatches.prefix(Self.maximumCustomSwatches))
    }

    private static func sanitized(_ placement: EditorToolbarPlacement) -> EditorToolbarPlacement {
        guard case let .floating(point) = placement else { return placement }
        guard point.x.isFinite, point.y.isFinite else { return standardPlacement }
        return .floating(CGPoint(x: max(0, min(point.x, 1)), y: max(0, min(point.y, 1))))
    }

    /// Decodes stored preferences. Missing, corrupt or unknown-version data yields `standard`;
    /// a missing or unknown writing mode yields focus and keeps everything else.
    public static func decode(_ data: Data?) -> EditorToolbarPreferences {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == currentVersion, let placement = stored.placement.resolved else { return .standard }
        return EditorToolbarPreferences(
            placement: placement,
            isCollapsed: stored.collapsed,
            customSwatches: stored.swatches.compactMap(EditorInkColor.init(components:)),
            chromeMode: stored.chromeMode.flatMap(EditorChromeMode.init(rawValue:)) ?? .focus
        )
    }

    public func encoded() -> Data {
        let stored = Stored(
            version: Self.currentVersion,
            placement: Stored.Placement(placement),
            collapsed: isCollapsed,
            swatches: customSwatches.map(\.components),
            chromeMode: chromeMode.rawValue
        )
        // Placements and colours are always finite, which is all JSON encoding requires.
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    private struct Stored: Codable {
        struct Point: Codable {
            let x: Double
            let y: Double
        }

        struct Placement: Codable {
            var dock: String?
            var floating: Point?

            init(_ placement: EditorToolbarPlacement) {
                switch placement {
                case let .docked(dock): self.dock = dock.rawValue
                case let .floating(point): floating = Point(x: point.x, y: point.y)
                }
            }

            /// JSON cannot hold a non-finite number, and the initializer clamps the rest.
            var resolved: EditorToolbarPlacement? {
                if let dock { return EditorToolbarDock(rawValue: dock).map { .docked($0) } }
                return floating.map { .floating(CGPoint(x: $0.x, y: $0.y)) }
            }
        }

        let version: Int
        let placement: Placement
        let collapsed: Bool
        let swatches: [[Double]]
        /// Added within version 1, so preferences stored before writing modes lack it.
        let chromeMode: String?
    }
}
