import CoreGraphics

/// How the editor's header and tools behave while writing. Raw values are stored, so they
/// must never change.
public enum EditorChromeMode: String, CaseIterable, Sendable {
    /// Header and tools leave the page while writing and return on request.
    case focus = "focus"
    /// Header and tools always stay visible.
    case pinned = "pinned"
    /// The tools always stay over the page while the header scrolls away. Shown to users as
    /// "Always-on tools".
    case overlay = "overlay"
}

/// Conditions that keep the header and tools visible in every mode, so a problem or an
/// interaction in progress is never hidden.
public enum EditorChromePin: CaseIterable, Hashable, Sendable {
    /// The notebook is not open for writing: full, failed, recovering or read-only.
    case inputPaused
    case saveProblem
    case integrityDamage
    /// A popover, sheet or menu is open.
    case presentation
    /// The toolbar is being dragged.
    case dragging
    /// Keyboard focus is in the header or toolbar.
    case keyboardFocus
    /// VoiceOver or Switch Control is running.
    case assistiveTechnology
}

/// A request to bring hidden chrome back. The kinds differ in how long the chrome stays, so a
/// quick Apple Pencil tool switch never leaves the header covering the page.
public enum EditorChromeReveal: Sendable {
    /// Shows the header and tools until the next hide trigger: the reveal handle, the keyboard
    /// shortcut, the accessibility action or an Apple Pencil palette request.
    case sticky
    /// Shows only the tools, briefly: an Apple Pencil tool switch.
    case transient
}

/// The result of a reveal. Besides the visibility change every input reports, a transient reveal
/// hands back the token that later ends it, since the state keeps no timers of its own.
public struct EditorChromeRevealOutcome: Equatable, Sendable {
    /// Whether the header, tools or reveal handle changed, so the app knows to animate.
    public let visibilityChanged: Bool
    /// For a transient reveal, the token to pass to `EditorChromeState.expireTransient(_:)`
    /// once `EditorChromeState.transientRevealDuration` has passed; nil for a sticky reveal.
    public let transientToken: UInt64?
}

/// Decides when the editor shows its header and tools. A deterministic state machine with no
/// timers: every input reports whether visibility changed, so the app animates only real changes.
///
/// Visibility never changes layout insets. The app reserves the chrome's space as if it were
/// fully shown, so hiding or revealing never moves the page.
///
/// Scrolling must be reported only when the user drives it, while the notebook is dragged or
/// decelerating. Programmatic offsets, layout adjustments, zoom-only changes and the canvas's
/// own scrolling during a stroke would otherwise hide or reveal the chrome by themselves.
///
/// Travel is net: scrolling back takes away from the distance counted, never below zero, so a
/// slow drag's small reversals neither reset nor stall it, and a small correction while reading
/// reveals nothing once reading carries on.
///
/// While any pin is set the header and tools show in every mode. Inputs still update the
/// requested state underneath, which takes effect once the pins clear.
public struct EditorChromeState: Equatable, Sendable {
    /// Downward travel that hides the chrome. Under Reduce Motion the header fades out here
    /// instead of following the page.
    public static let hideTravel: CGFloat = 28
    /// Upward travel that reveals it.
    public static let revealTravel: CGFloat = 28
    public static let transientRevealDuration = Duration.seconds(1.5)

    public private(set) var mode: EditorChromeMode
    public private(set) var pins: Set<EditorChromePin> = []
    /// Whether the user asked to see the chrome this mode can hide: the header, and in focus
    /// mode the tools as well.
    private var isRevealed = true
    /// The transient reveal currently showing the tools, recorded only in focus mode.
    private var activeTransient: UInt64?
    private var lastTransient: UInt64 = 0
    private var isToolActive = false
    /// Whether the page rested at its top when last reported, by scrolling or by
    /// `pageMoved(isAtTop:)`. Until the app reports otherwise, the page is taken to start there.
    private var wasAtTop = true
    /// Net travel into the notebook since travel last restarted: how far below the highest point
    /// reached the notebook now sits.
    private var descent: CGFloat = 0
    /// Net travel back toward the top over the same span.
    private var ascent: CGFloat = 0

    public init(mode: EditorChromeMode = .focus) {
        self.mode = mode
    }

    public var showsHeader: Bool { isForcedVisible || isRevealed }

    /// How far a header that follows the page has moved up with it: the net travel into the
    /// notebook since the header last showed, a scroll last came to rest, a stroke began or pins
    /// last began or stopped holding it in place. It stays below `hideTravel`, since reaching
    /// that hides the header. Zero while the header is hidden or kept in place.
    public var headerTravel: CGFloat { isRevealed && !isForcedVisible ? descent : 0 }

    public var showsTools: Bool {
        isForcedVisible || mode == .overlay || isRevealed || activeTransient != nil
    }

    /// Stands in for the tools while focus mode hides them.
    public var showsRevealHandle: Bool { mode == .focus && !showsTools }

    private var isForcedVisible: Bool { mode == .pinned || !pins.isEmpty }

    /// A new mode shows everything, since the user has just chosen it; choosing the current
    /// mode again changes nothing.
    @discardableResult
    public mutating func setMode(_ mode: EditorChromeMode) -> Bool {
        guard mode != self.mode else { return false }
        return changingVisibility {
            $0.mode = mode
            $0.show()
        }
    }

    /// A header following the page goes back in place when pinned, and stays there as the pins
    /// clear, so travel counts afresh from each change; what scrolling asked for underneath stays.
    @discardableResult
    public mutating func setPins(_ pins: Set<EditorChromePin>) -> Bool {
        changingVisibility {
            let wasForcedVisible = $0.isForcedVisible
            $0.pins = pins
            if $0.isForcedVisible != wasForcedVisible { $0.restartTravel() }
        }
    }

    /// Never changes visibility, so nothing moves under the pen as a stroke starts.
    @discardableResult
    public mutating func toolBegan() -> Bool {
        changingVisibility {
            $0.isToolActive = true
            $0.restartTravel()
        }
    }

    /// In focus mode a finished stroke clears the header and tools from the page.
    @discardableResult
    public mutating func toolEnded() -> Bool {
        changingVisibility {
            $0.isToolActive = false
            if $0.mode == .focus { $0.hide() }
        }
    }

    /// Ends a tool use whose end will never be reported, such as a stroke cut short by its
    /// canvas being torn down or replaced. Scrolling counts again, but nothing hides, since no
    /// stroke was finished. Never changes visibility.
    @discardableResult
    public mutating func toolCancelled() -> Bool {
        changingVisibility { $0.isToolActive = false }
    }

    /// Reports user scrolling by `delta` points, positive further into the notebook.
    /// `isAtTop` is true while the notebook rests at or above its top, overscroll included.
    ///
    /// Report movement past the top as it happens: the state recognises the settle-back there
    /// itself, and a pull-down at the top reveals like any upward scroll. Movement past the
    /// notebook's end must not count, because a fling that overshoots the bottom springs back
    /// with upward deltas that would otherwise reveal the chrome. Clamp the offset to the end
    /// before taking each delta, so the settle-back reports nothing.
    ///
    /// Arriving at the top reveals the chrome; staying there does not, so a stroke written at
    /// the top still leaves a clean page. Ignored while a tool is in use. Report a status-bar
    /// scroll to the top through `scrolledToTop()`, and a page that something other than the
    /// user moved through `pageMoved(isAtTop:)`.
    @discardableResult
    public mutating func userScrolled(by delta: CGFloat, isAtTop: Bool) -> Bool {
        guard !isToolActive else { return false }
        return changingVisibility { $0.scroll(by: delta, isAtTop: isAtTop) }
    }

    /// Records where the page rests after something other than the user moved it: opening below
    /// its top, a resize, or a change in the space kept for the chrome. The next arrival at the
    /// top counts from there. Never changes visibility.
    public mutating func pageMoved(isAtTop: Bool) {
        wasAtTop = isAtTop
    }

    /// The status-bar tap's scroll to the top has settled. It is the user's own request, so it
    /// shows everything the mode can hide wherever the page rested before, and the page now rests
    /// at the top. Ignored while a tool is in use.
    @discardableResult
    public mutating func scrolledToTop() -> Bool {
        guard !isToolActive else { return false }
        return changingVisibility {
            $0.wasAtTop = true
            $0.show()
        }
    }

    /// The user's scrolling has come to rest. Travel short of either threshold is dropped, as a
    /// header left part-way settles back, so the next scroll starts from nothing. Never changes
    /// visibility.
    public mutating func userScrollEnded() {
        restartTravel()
    }

    @discardableResult
    public mutating func reveal(_ kind: EditorChromeReveal) -> EditorChromeRevealOutcome {
        switch kind {
        case .sticky:
            return EditorChromeRevealOutcome(visibilityChanged: changingVisibility { $0.show() }, transientToken: nil)
        case .transient:
            lastTransient += 1
            let token = lastTransient
            let changed = changingVisibility { if $0.mode == .focus { $0.activeTransient = token } }
            return EditorChromeRevealOutcome(visibilityChanged: changed, transientToken: token)
        }
    }

    /// Ends the transient reveal identified by `token`. Does nothing once a newer reveal, a hide
    /// trigger or a mode change has superseded it, or while pinned: a transient that outlasts
    /// its time under a pin keeps the tools up until the next hide trigger.
    @discardableResult
    public mutating func expireTransient(_ token: UInt64) -> Bool {
        guard activeTransient == token, pins.isEmpty else { return false }
        return changingVisibility { $0.activeTransient = nil }
    }

    /// The keyboard shortcut: hides the chrome this mode can hide when the user has it shown,
    /// and otherwise reveals it to stay. Nothing changes in pinned mode.
    @discardableResult
    public mutating func toggle() -> Bool {
        guard mode != .pinned else { return false }
        return changingVisibility {
            if $0.isRevealed { $0.hide() } else { $0.show() }
        }
    }

    private mutating func scroll(by delta: CGFloat, isAtTop: Bool) {
        let arrived = isAtTop && !wasAtTop
        wasAtTop = isAtTop
        if arrived {
            show()
            return
        }
        guard delta.isFinite, delta != 0 else { return }
        // Moving down while still at the top is overscroll settling back, not reading on.
        if isAtTop, delta > 0 {
            restartTravel()
            return
        }
        descent = max(descent + delta, 0)
        ascent = max(ascent - delta, 0)
        if descent >= Self.hideTravel {
            hide()
        } else if ascent >= Self.revealTravel {
            show()
        }
    }

    private mutating func restartTravel() {
        descent = 0
        ascent = 0
    }

    /// Shows everything the mode can hide and supersedes any transient reveal.
    private mutating func show() {
        isRevealed = true
        activeTransient = nil
        restartTravel()
    }

    /// A hide trigger, which also cancels any transient reveal. Pinned mode never hides.
    private mutating func hide() {
        guard mode != .pinned else { return }
        isRevealed = false
        activeTransient = nil
        restartTravel()
    }

    private mutating func changingVisibility(_ change: (inout EditorChromeState) -> Void) -> Bool {
        let before = visibility
        change(&self)
        return visibility != before
    }

    private var visibility: (header: Bool, tools: Bool, handle: Bool) {
        (showsHeader, showsTools, showsRevealHandle)
    }
}
