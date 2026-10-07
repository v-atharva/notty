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
/// While any pin is set the header and tools show in every mode. Inputs still update the
/// requested state underneath, which takes effect once the pins clear.
public struct EditorChromeState: Equatable, Sendable {
    /// Downward travel that hides the chrome.
    public static let hideTravel: CGFloat = 24
    /// Upward travel that reveals it, a little more than hiding takes so a small correction
    /// while reading leaves the page clear.
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
    /// Notebooks open at their top, so the first scroll there is not an arrival.
    private var wasAtTop = true
    /// Travel since the last reversal or visibility request; positive moves into the notebook.
    private var travel: CGFloat = 0

    public init(mode: EditorChromeMode = .focus) {
        self.mode = mode
    }

    public var showsHeader: Bool { isForcedVisible || isRevealed }

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

    @discardableResult
    public mutating func setPins(_ pins: Set<EditorChromePin>) -> Bool {
        changingVisibility { $0.pins = pins }
    }

    /// Never changes visibility, so nothing moves under the pen as a stroke starts.
    @discardableResult
    public mutating func toolBegan() -> Bool {
        changingVisibility {
            $0.isToolActive = true
            $0.travel = 0
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
    /// the top still leaves a clean page. A scroll-to-top tap is the user's own request: report
    /// its arrival once it settles, with a `delta` of zero. Ignored while a tool is in use.
    @discardableResult
    public mutating func userScrolled(by delta: CGFloat, isAtTop: Bool) -> Bool {
        guard !isToolActive else { return false }
        return changingVisibility { $0.scroll(by: delta, isAtTop: isAtTop) }
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
            travel = 0
            return
        }
        if travel != 0, (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel >= Self.hideTravel {
            hide()
        } else if travel <= -Self.revealTravel {
            show()
        }
    }

    /// Shows everything the mode can hide and supersedes any transient reveal.
    private mutating func show() {
        isRevealed = true
        activeTransient = nil
        travel = 0
    }

    /// A hide trigger, which also cancels any transient reveal. Pinned mode never hides.
    private mutating func hide() {
        guard mode != .pinned else { return }
        isRevealed = false
        activeTransient = nil
        travel = 0
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
