import Foundation

/// The scratchpad's trial of a colour, which decides whether leaving the colour screen keeps it.
/// The first stroke on the scratchpad starts the trial: a border draws itself once around the
/// scratchpad over `holdDuration`, and the colour is retained from the moment the border closes.
/// Choosing another colour after that first stroke starts the border again, so a colour is kept
/// only once it has been on the paper for the whole span.
///
/// Times are seconds on the caller's clock, which tests replace.
public struct InkTrialTimeline: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing drawn yet: leaving keeps the ink as it was, and no border shows.
        case untried
        /// The border is drawing: leaving still keeps the ink as it was.
        case trying
        /// The border has closed: leaving writes with the colour and adds it to the swatches.
        case retained
    }

    public static let holdDuration: TimeInterval = 3.5

    /// When the trial of the colour showing began.
    public private(set) var startedAt: TimeInterval?

    public init() {}

    public func phase(at now: TimeInterval) -> Phase {
        guard let startedAt else { return .untried }
        return now - startedAt >= Self.holdDuration ? .retained : .trying
    }

    /// When a trial under way turns retained by itself.
    public var retainsAt: TimeInterval? {
        startedAt.map { $0 + Self.holdDuration }
    }

    /// How much of the border shows, from 0 at its start to 1 once it closes. The border grows at
    /// an even pace, so its length tells the time left. Under Reduce Motion it shows whole from the
    /// first stroke, and only its colour changes once the hold ends.
    public func borderProgress(at now: TimeInterval, reduceMotion: Bool) -> Double {
        guard let startedAt else { return 0 }
        if reduceMotion { return 1 }
        return min(max((now - startedAt) / Self.holdDuration, 0), 1)
    }

    /// The "Color selected" toast stands for the retained phase: it shows exactly while leaving
    /// would keep the colour.
    public func showsToast(at now: TimeInterval) -> Bool {
        phase(at: now) == .retained
    }

    /// A stroke began on the scratchpad. Only the first starts the trial; later strokes leave it
    /// running.
    public mutating func beginStroke(at now: TimeInterval) {
        if startedAt == nil { startedAt = now }
    }

    /// Another colour is showing. A trial already started begins again for it, from no border.
    public mutating func changeColor(at now: TimeInterval) {
        if startedAt != nil { startedAt = now }
    }
}
