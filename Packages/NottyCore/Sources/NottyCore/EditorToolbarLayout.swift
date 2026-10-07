import CoreGraphics
import Foundation

/// Where a docked toolbar rests: across the top centre as a horizontal rail, or against the left
/// or right edge as a vertical one. Raw values are stored, so they must never change.
///
/// The side docks keep the stored names of the top-left and top-right docks they replaced. A
/// toolbar docked in a top corner before the side docks existed moves to the edge it sat against,
/// and a build from before them reads a side dock as that corner instead of rejecting the stored
/// preferences and losing the custom colours and writing mode kept with it.
public enum EditorToolbarDock: String, CaseIterable, Sendable {
    case leftEdge = "topLeading"
    case topCenter = "topCenter"
    case rightEdge = "topTrailing"

    public var axis: EditorToolbarAxis { self == .topCenter ? .horizontal : .vertical }
}

/// Which way a toolbar's rows run.
public enum EditorToolbarAxis: Sendable {
    case horizontal
    case vertical
}

public enum EditorToolbarPlacement: Equatable, Sendable {
    case docked(EditorToolbarDock)
    /// Toolbar centre as fractions of the usable bounds, so rotation and window
    /// resizing keep it in the same relative place.
    case floating(CGPoint)

    /// A floating toolbar is always horizontal.
    public var axis: EditorToolbarAxis {
        if case let .docked(dock) = self { return dock.axis }
        return .horizontal
    }
}

/// The finger holding a dragged toolbar: where it is, and how far it has moved since the drag began.
public struct EditorToolbarDragFinger: Equatable, Sendable {
    public var location: CGPoint
    public var travel: CGSize

    public init(location: CGPoint, travel: CGSize) {
        self.location = location
        self.travel = travel
    }
}

/// Pure frame calculations for the editor toolbar, independent of any view.
public enum EditorToolbarLayout {
    public static let margin: CGFloat = 12
    /// How close a dragged toolbar's top must come to the top dock's to snap into it, and how
    /// close a vertical toolbar's edge must stay to its side dock's to stay there.
    public static let snapDistance: CGFloat = 56
    /// How close to the left or right side of the usable bounds, or to its top, a finger must end
    /// to dock there.
    public static let edgeSnapDistance: CGFloat = 64
    /// How far the finger must have moved toward a side, or up toward the top, for that dock to
    /// take it. A grip that starts within reach of an edge docks nowhere until the finger heads
    /// there, so a rail dragged straight into the page floats.
    public static let edgeApproachDistance: CGFloat = 16

    /// The sizes a toolbar takes at the top dock and at the side docks.
    public struct DockSizes: Equatable, Sendable {
        public var horizontal: CGSize
        public var vertical: CGSize

        public init(horizontal: CGSize, vertical: CGSize) {
            self.horizontal = horizontal
            self.vertical = vertical
        }

        public func size(for dock: EditorToolbarDock) -> CGSize {
            dock.axis == .horizontal ? horizontal : vertical
        }
    }

    /// The frame a toolbar of `size` takes at `placement`. A side dock centres the toolbar along
    /// its edge; the top dock centres it below the top margin. A floating toolbar centres on its
    /// point, or `centreOffset` from it for a view that stands for part of the toolbar there.
    public static func frame(
        for placement: EditorToolbarPlacement, size: CGSize, in usable: CGRect, centreOffset: CGSize = .zero
    ) -> CGRect {
        let origin: CGPoint
        switch placement {
        case let .docked(dock):
            switch dock {
            case .topCenter:
                origin = CGPoint(x: usable.midX - size.width / 2, y: usable.minY + margin)
            case .leftEdge:
                origin = CGPoint(x: usable.minX + margin, y: usable.midY - size.height / 2)
            case .rightEdge:
                origin = CGPoint(x: usable.maxX - margin - size.width, y: usable.midY - size.height / 2)
            }
        case let .floating(fraction):
            let center = CGPoint(
                x: usable.minX + clampUnit(fraction.x) * usable.width + centreOffset.width,
                y: usable.minY + clampUnit(fraction.y) * usable.height + centreOffset.height
            )
            origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        }
        return clamped(CGRect(origin: origin, size: size), in: usable)
    }

    /// Resolves where a toolbar dragged to `frame`, held by `finger` when known, comes to rest.
    ///
    /// A horizontal toolbar docks at the top when its top centre ends within `snapDistance` of the
    /// docked toolbar's top centre, whatever its size, so a rail and a collapsed handle dock there
    /// the same way. A vertical toolbar spans most of the height, so its top lies near the top dock
    /// wherever it is dragged; only the finger, taken up to within `edgeDistance` of the top, docks
    /// it there. A side dock takes a drag whose finger ends within `edgeDistance` of that side
    /// having moved toward it: a wide rail held by its grip can hardly move sideways, so only the
    /// finger says which edge it is pushed to. A vertical toolbar also stays docked at a side while
    /// its edge stays within `snapDistance` of the dock's. Anything else floats at the clamped
    /// location, less `centreOffset` for a frame that `frame(for:size:in:centreOffset:)` places that
    /// far from the toolbar's point. Without `sideDocks` the sides are not docks at all.
    public static func placement(
        forDragEnding frame: CGRect, finger: EditorToolbarDragFinger?, dockSizes: DockSizes, in usable: CGRect,
        sideDocks: Bool = true, snapDistance: CGFloat = snapDistance, edgeDistance: CGFloat = edgeSnapDistance,
        centreOffset: CGSize = .zero
    ) -> EditorToolbarPlacement {
        guard usable.width > 0, usable.height > 0 else { return .docked(.topCenter) }
        let isVertical = abs(frame.width - dockSizes.vertical.width) < 0.5
            && abs(frame.height - dockSizes.vertical.height) < 0.5
        if isVertical {
            if let finger, reaches(gap: finger.location.y - usable.minY, travel: -finger.travel.height, within: edgeDistance) {
                return .docked(.topCenter)
            }
        } else {
            let top = self.frame(for: .docked(.topCenter), size: dockSizes.horizontal, in: usable)
            if distance(CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: top.midX, y: top.minY)) <= snapDistance {
                return .docked(.topCenter)
            }
        }
        if sideDocks, let dock = sideDock(
            forDragEnding: frame, finger: finger, isVertical: isVertical, size: dockSizes.vertical, in: usable,
            snapDistance: snapDistance, edgeDistance: edgeDistance
        ) {
            return .docked(dock)
        }
        let rest = clamped(frame, in: usable)
        return .floating(CGPoint(
            x: clampUnit((rest.midX - centreOffset.width - usable.minX) / usable.width),
            y: clampUnit((rest.midY - centreOffset.height - usable.minY) / usable.height)
        ))
    }

    /// The side a drag ends at, the nearer one when both qualify.
    private static func sideDock(
        forDragEnding frame: CGRect, finger: EditorToolbarDragFinger?, isVertical: Bool, size: CGSize,
        in usable: CGRect, snapDistance: CGFloat, edgeDistance: CGFloat
    ) -> EditorToolbarDock? {
        let gaps: [(EditorToolbarDock, CGFloat)] = [EditorToolbarDock.leftEdge, .rightEdge].compactMap { dock in
            let isLeft = dock == .leftEdge
            if let finger {
                let gap = isLeft ? finger.location.x - usable.minX : usable.maxX - finger.location.x
                let travel = isLeft ? -finger.travel.width : finger.travel.width
                if reaches(gap: gap, travel: travel, within: edgeDistance) { return (dock, max(gap, 0)) }
            }
            let slot = self.frame(for: .docked(dock), size: size, in: usable)
            let edgeGap = isLeft ? abs(frame.minX - slot.minX) : abs(frame.maxX - slot.maxX)
            if isVertical, edgeGap <= snapDistance { return (dock, edgeGap) }
            return nil
        }
        return gaps.min { $0.1 < $1.1 }?.0
    }

    /// Whether a finger `gap` from an edge, having moved `travel` toward it, has reached that edge.
    private static func reaches(gap: CGFloat, travel: CGFloat, within edgeDistance: CGFloat) -> Bool {
        gap.isFinite && gap <= edgeDistance && travel >= edgeApproachDistance
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

    /// Decodes stored preferences. Missing, corrupt or unknown-version data yields `standard`. An
    /// unknown placement yields the standard dock and a missing or unknown writing mode yields
    /// focus, each keeping everything else, so the custom colours are never lost with them.
    public static func decode(_ data: Data?) -> EditorToolbarPreferences {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == currentVersion else { return .standard }
        return EditorToolbarPreferences(
            placement: stored.placement.resolved ?? standardPlacement,
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
