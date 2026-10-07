import Combine
import NottyCore
import PencilKit
import SwiftUI
import UIKit

// The custom colour well opens a screen of its own: a dark picker panel, a bar of shades along the
// bottom and, once a colour is chosen, a scratchpad of notebook paper where the ink can be tried.
// A border drawing itself around the scratchpad shows when the colour would be kept: a tap
// anywhere else leaves the screen, and only a colour tried until the border turns green reaches
// the notes. Nothing drawn on the scratchpad is ever kept.

extension View {
    /// Presents the colour screen over the whole window while `isPresented` holds. The writing
    /// view keeps its header and tools pinned meanwhile, and closing the writing gate closes the
    /// screen without applying anything.
    func notebookColorScreen(isPresented: Binding<Bool>, store: NotebookSceneToolStore) -> some View {
        modifier(NotebookColorScreenPresentation(isPresented: isPresented, store: store))
    }
}

private struct NotebookColorScreenPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let store: NotebookSceneToolStore
    /// Follows `isPresented` without UIKit's slide from the bottom, which would carry the shade bar
    /// with it: the screen fades in and brings its own parts.
    @State private var showsCover = false

    func body(content: Content) -> some View {
        content
            // SwiftUI presents the cover in UIKit's .overFullScreen style, which leaves the notebook
            // in the window beneath, so its canvas keeps the tools and the eyedropper can picture it.
            .fullScreenCover(isPresented: $showsCover) {
                NotebookColorPickerScreen(store: store) { isPresented = false }
                    .ignoresSafeArea()
                    .presentationBackground(.clear)
                    // The well sits on the rail's glass, which the cover inherits and hands on to
                    // the SwiftUI views the screen hosts; the screen is matte, as the popovers are.
                    .environment(\.notebookKeysOnGlass, false)
            }
            .onChange(of: isPresented) { _, presented in
                withTransaction(\.disablesAnimations, true) { showsCover = presented }
            }
            .notebookToolbarPresentation(isPresented, store: store)
            // Every change arrives, however many fall within one frame, so a pause always closes it.
            .onReceive(store.$isToolbarAvailable) { available in
                if !available { isPresented = false }
            }
    }
}

/// The colour screen as SwiftUI presents it.
struct NotebookColorPickerScreen: UIViewControllerRepresentable {
    let store: NotebookSceneToolStore
    let close: @MainActor () -> Void

    func makeUIViewController(context: Context) -> NotebookColorPickerScreenController {
        NotebookColorPickerScreenController(store: store, close: close)
    }

    func updateUIViewController(_ controller: NotebookColorPickerScreenController, context: Context) {
        controller.close = close
    }
}

// MARK: - Layout

/// Where the picker, the scratchpad and the exit hint sit inside the screen's content area, above
/// the shade bar. The picker keeps one size in both states, so making room for the scratchpad only
/// moves it. Side by side it glides left; on a window too narrow for both it glides up and the
/// scratchpad comes in below. Room is kept above the scratchpad for the "Color Selected" toast, and
/// the hint lies centred under the cards. On a short window the picker's square gives way first,
/// down to its minimum; cards still too tall for the room keep their lower edge in place, so the
/// fields stay in sight above the shades or a docked keyboard, and run past the top instead.
struct NotebookColorPickerLayout: Equatable {
    enum Arrangement: Equatable {
        case sideBySide
        case stacked
    }

    let arrangement: Arrangement
    /// The picker alone, centred, before a colour is chosen.
    let centredPicker: CGRect
    /// The picker once the scratchpad shows.
    let picker: CGRect
    let scratchpad: CGRect
    let hint: CGRect

    /// - Parameters:
    ///   - content: the safe area inside the screen's margins, above the shade bar.
    ///   - pickerHeight: the height the picker asks for at a width.
    ///   - pickerMinimumHeight: the least height the picker takes, its square at its minimum.
    ///   - toastRoom: the toast's height and its gap above the scratchpad.
    ///   - hintHeight: the height the exit hint needs at the content's width.
    init(
        content: CGRect, pickerHeight: (CGFloat) -> CGFloat, pickerMinimumHeight: CGFloat, toastRoom: CGFloat,
        hintHeight: CGFloat
    ) {
        let hintRoom = hintHeight + NotebookTheme.colorScreenHintGap
        let besideWidth = min(
            NotebookTheme.colorPickerWidth, content.width - NotebookTheme.colorScreenCardGap - NotebookTheme.scratchpadMinimumWidth
        )
        // The picker's height at `width` within `room`, never under its minimum.
        func fittedPickerHeight(_ width: CGFloat, within room: CGFloat) -> CGFloat {
            let preferred = pickerHeight(width)
            return max(min(preferred, room), min(pickerMinimumHeight, preferred))
        }
        // How far down `room` cards of `height` start: centred where they fit, otherwise flush
        // with its bottom.
        func offset(of height: CGFloat, in room: CGFloat) -> CGFloat {
            let slack = room - height
            return min(slack / 2, slack)
        }
        let groupBottom: CGFloat
        if besideWidth >= NotebookTheme.colorPickerMinimumWidth {
            let gap = NotebookTheme.colorScreenCardGap
            let cardRoom = max(content.height - toastRoom - hintRoom, 0)
            let height = fittedPickerHeight(besideWidth, within: cardRoom)
            let scratchWidth = min(NotebookTheme.scratchpadMaximumWidth, content.width - gap - besideWidth)
            let groupWidth = besideWidth + gap + scratchWidth
            let top = content.minY + toastRoom + offset(of: height, in: cardRoom)
            let left = content.minX + (content.width - groupWidth) / 2
            arrangement = .sideBySide
            centredPicker = CGRect(x: content.midX - besideWidth / 2, y: top, width: besideWidth, height: height)
            picker = CGRect(x: left, y: top, width: besideWidth, height: height)
            scratchpad = CGRect(x: picker.maxX + gap, y: top, width: scratchWidth, height: height)
            groupBottom = picker.maxY
        } else {
            // The toast rests between the two cards.
            let gap = max(NotebookTheme.colorScreenCardGap, toastRoom)
            let width = min(NotebookTheme.colorPickerWidth, content.width)
            let cardRoom = max(content.height - hintRoom, 0)
            let height = fittedPickerHeight(width, within: cardRoom - gap - NotebookTheme.scratchpadMinimumHeight)
            let scratchHeight = max(min(NotebookTheme.scratchpadStackedHeight, cardRoom - gap - height), 0)
            let groupHeight = height + gap + scratchHeight
            let left = content.midX - width / 2
            let top = content.minY + offset(of: groupHeight, in: cardRoom)
            arrangement = .stacked
            centredPicker = CGRect(x: left, y: top + (groupHeight - height) / 2, width: width, height: height)
            picker = CGRect(x: left, y: top, width: width, height: height)
            scratchpad = CGRect(x: left, y: picker.maxY + gap, width: width, height: scratchHeight)
            groupBottom = scratchpad.maxY
        }
        hint = CGRect(
            x: content.minX, y: groupBottom + NotebookTheme.colorScreenHintGap, width: content.width, height: hintHeight
        )
    }

    func pickerFrame(showingScratchpad: Bool) -> CGRect {
        showingScratchpad ? picker : centredPicker
    }

    /// Where the scratchpad starts as it slides into place: a little beyond it, away from the picker.
    var scratchpadEntryOffset: CGVector {
        switch arrangement {
        case .sideBySide: CGVector(dx: NotebookTheme.scratchpadEntryOffset, dy: 0)
        case .stacked: CGVector(dx: 0, dy: NotebookTheme.scratchpadEntryOffset)
        }
    }
}

// MARK: - Screen

/// The full-screen colour screen: the picker panel, the shade bar, the scratchpad that appears
/// beside the panel once a colour is chosen, the eyedropper, and a quiet hint that a tap anywhere
/// else leaves.
@MainActor
final class NotebookColorPickerScreenController: UIViewController, UIGestureRecognizerDelegate {
    static let exitLabel = "Exit"
    static let exitKeepsHint = "Writes with the color you tried and adds it to your swatches."
    static let exitLeavesHint = "Your ink stays as it was."
    static let selectedAnnouncement = "Color selected"
    static let fadeKey = "reduceMotionFade"
    static let fadeStepKey = "reduceMotionStep"

    let panel: NotebookColorPickerPanel
    let scratchpad = NotebookScratchpadController()
    let shadeBar = NotebookShadeBar()
    let toast = UIHostingController(rootView: NotebookColorSelectedToast())
    let exitHint = NotebookColorScreenExitHint()
    /// A tap, not a drag, by finger or Pencil, anywhere off the panel, the scratchpad and the shades.
    let exitTap = UITapGestureRecognizer()
    var close: @MainActor () -> Void
    /// Reduce Motion as the screen reads it, replaceable in tests.
    var prefersCrossFade: @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    /// The clock the trial runs on, replaceable in tests. Core Animation's, so the border's drawing
    /// and its turn to green share one timeline.
    var now: @MainActor () -> TimeInterval = { CACurrentMediaTime() }
    /// The view the eyedropper pictures as the screen opens: the notebook beneath.
    var pageSource: @MainActor (NotebookColorPickerScreenController) -> UIView? = { $0.notebookPage() }
    private(set) var snapshot: NotebookPageSnapshot?
    private(set) var eyedropper: NotebookEyedropperView?
    /// The colour showing.
    private(set) var color: EditorHSBColor
    /// The hue and saturation the shade bar spreads. A tapped shade leaves it as it is, so the bar
    /// holds still under the finger and its ring moves to the tapped step.
    private(set) var shadeBase: EditorHSBColor
    private(set) var showsScratchpad = false
    private(set) var layout: NotebookColorPickerLayout?
    private(set) var trial = InkTrialTimeline()
    /// The phase the scratchpad shows. Leaving acts on it, so what the user sees is what happens.
    private(set) var trialPhase = InkTrialTimeline.Phase.untried
    /// Whether the "Color Selected" toast is up, as the trial decides.
    private(set) var isToastShown = false
    private(set) var isClosing = false
    /// How far up from the bottom edge a docked software keyboard reaches. The cards keep above it,
    /// so the fields stay in sight while they are typed in.
    private(set) var keyboardCover: CGFloat = 0

    private let store: NotebookSceneToolStore
    private var toolSubscription: AnyCancellable?
    private var trialTask: Task<Void, Never>?
    private var hasEntered = false

    init(store: NotebookSceneToolStore, close: @escaping @MainActor () -> Void) {
        self.store = store
        self.close = close
        let color = EditorHSBColor(store.tool.color)
        self.color = color
        shadeBase = color
        panel = NotebookColorPickerPanel(color: color)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(store:close:).")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NotebookTheme.backdropStone.uiColor
        // The screen continues the editor, which is always light.
        overrideUserInterfaceStyle = .light
        // The notebook stays in the window beneath, so VoiceOver must not wander onto it.
        view.accessibilityViewIsModal = true
        // The fields and keys keep their sizes, so their text grows only so far.
        view.maximumContentSizeCategory = .extraExtraLarge

        // The scratchpad lies under the panel, so the panel passes over it as it glides.
        addChild(scratchpad)
        view.addSubview(scratchpad.view)
        scratchpad.didMove(toParent: self)
        setScratchpadReachable(false)
        scratchpad.view.alpha = 0
        scratchpad.onBeginStroke = { [weak self] in self?.updateTrial { $0.beginStroke(at: $1) } }
        scratchpad.ink = Self.ink(trying: color.rgb, with: store.tool)

        panel.onChange = { [weak self] color, change in self?.show(color, change: change) }
        panel.onEyedropper = { [weak self] in self?.startEyedropper() }
        view.addSubview(panel)

        addChild(toast)
        toast.safeAreaRegions = []
        toast.view.backgroundColor = .clear
        toast.view.isHidden = true
        view.addSubview(toast.view)
        toast.didMove(toParent: self)

        exitHint.onActivate = { [weak self] in self?.leave() }
        view.addSubview(exitHint)
        refreshExitHint()

        shadeBar.onSelect = { [weak self] index in self?.chooseShade(at: index) }
        view.addSubview(shadeBar)

        exitTap.addTarget(self, action: #selector(tappedOutside))
        exitTap.delegate = self
        exitTap.cancelsTouchesInView = false
        view.addGestureRecognizer(exitTap)

        refreshAccessibilityOrder()
        // A Pencil gesture can change the ink while the screen is open; the scratchpad follows.
        toolSubscription = store.$tool.dropFirst().sink { [weak self] tool in
            guard let self else { return }
            scratchpad.ink = Self.ink(trying: color.rgb, with: tool)
        }
        registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { (controller: NotebookColorPickerScreenController, _: UITraitCollection) in
            controller.view.setNeedsLayout()
        }
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: name, object: nil)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The notebook still shows beneath, so this is the moment to picture it.
        if snapshot == nil { capturePage() }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !hasEntered else { return }
        hasEntered = true
        enter()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Keyboard commands reach this screen rather than the notebook beneath it.
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        trialTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        // The picture of the page holds one size and orientation only.
        if let eyedropper, eyedropper.frame.size != bounds.size { endEyedropper() }
        let safe = view.safeAreaInsets
        let barHeight = NotebookShadeBar.height(bottomInset: safe.bottom)
        place(shadeBar, in: CGRect(x: 0, y: bounds.maxY - barHeight, width: bounds.width, height: barHeight))
        refreshShades()

        let margin = NotebookTheme.colorScreenMargin
        let top = safe.top + margin
        let bottom = bounds.maxY - max(barHeight, keyboardCover) - margin
        let content = CGRect(
            x: safe.left + margin, y: top, width: max(bounds.width - safe.left - safe.right - 2 * margin, 0),
            height: max(bottom - top, 0)
        )
        let hintHeight = exitHint.sizeThatFits(
            CGSize(width: content.width, height: .greatestFiniteMagnitude)
        ).height.rounded(.up)
        let layout = NotebookColorPickerLayout(
            content: content, pickerHeight: { [panel] width in panel.height(forWidth: width) },
            pickerMinimumHeight: panel.minimumHeight, toastRoom: toastSize.height + NotebookTheme.colorToastGap,
            hintHeight: hintHeight
        )
        self.layout = layout
        place(panel, in: layout.pickerFrame(showingScratchpad: showsScratchpad))
        place(scratchpad.view, in: layout.scratchpad)
        exitHint.frame = layout.hint
        place(toast.view, in: toastFrame(over: layout.scratchpad))
        // The page fills the window's width, so the scratchpad shows its paper at that zoom.
        scratchpad.pageScale = bounds.width / CGFloat(NotebookPaperMetrics.pageWidth)
    }

    // MARK: Choosing

    /// Every colour the screen shows passes through here, whichever control reached it.
    func show(_ next: EditorHSBColor, change: NotebookColorChange, fromShades: Bool = false) {
        guard !isClosing else { return }
        let previous = color
        color = next
        if panel.color != next { panel.color = next }
        if !fromShades {
            // A change of hue or brightness keeps the bar's saturation, so a tapped tint stays lit.
            shadeBase = next.saturation == previous.saturation ? shadeBase.with(hue: next.hue, alpha: next.alpha) : next
        }
        refreshShades()
        scratchpad.ink = Self.ink(trying: next.rgb, with: store.tool)
        if !next.isSameColor(as: previous) { updateTrial { $0.changeColor(at: $1) } }
        // Moving the panel during a drag would move the colours under the finger, so it waits.
        if change == .settled { showScratchpad() }
    }

    /// The ink leaving would put in use with `color`: the colour as the shelf stores it, in the
    /// family and width in use, returning from the eraser or lasso to the ink before them.
    static func ink(trying color: EditorInkColor, with tool: EditorToolState) -> EditorToolState {
        var ink = tool
        if ink.inkFamily == nil { ink.selectPreviousInk() }
        ink.color = NotebookSwatchShelf.canonicalColor(color, preserving: tool.color)
        return ink
    }

    private func chooseShade(at index: Int) {
        guard shadeBar.shades.indices.contains(index) else { return }
        panel.finishEditing()
        show(shadeBar.shades[index], change: .settled, fromShades: true)
    }

    private func refreshShades() {
        let shades = EditorShadeRamp.steps(of: shadeBase, count: NotebookShadeBar.stepCount(forWidth: view.bounds.width))
        shadeBar.show(shades, selected: shades.firstIndex { $0.isSameColor(as: color) })
    }

    // MARK: Leaving

    /// Closes the screen. A colour tried until its border turned green becomes the ink and joins
    /// the swatches; otherwise the ink and the swatches stay as they were.
    func leave() {
        guard !isClosing else { return }
        // An entry still being typed counts, as it shows: a new value starts the trial again, while
        // one that only repeats the field leaves the colour, and a green border, as they were.
        panel.finishEditing()
        isClosing = true
        trialTask?.cancel()
        endEyedropper()
        if trialPhase == .retained {
            NotebookToolbarActions(store: store).addCustomColor(color.rgb)
        }
        exitTap.isEnabled = false
        let reduceMotion = prefersCrossFade()
        UIView.animate(
            withDuration: NotebookTheme.colorScreenExitDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.view.alpha = 0
            if !reduceMotion { self.shadeBar.transform = CGAffineTransform(translationX: 0, y: self.shadeBar.bounds.height) }
        } completion: { _ in
            self.close()
        }
    }

    /// True where a tap leaves the screen: anywhere but the panel, the scratchpad and the shade
    /// bar. Mid-glide a card counts both where it shows and where it is going, so a tap meant for
    /// it never leaves.
    func exitsOnTap(at point: CGPoint) -> Bool {
        let parts: [UIView] = showsScratchpad ? [panel, scratchpad.view, shadeBar] : [panel, shadeBar]
        return !parts.contains { part in
            part.frame.contains(point) || part.layer.presentation()?.frame.contains(point) == true
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        exitsOnTap(at: touch.location(in: view))
    }

    /// With the keyboard up, the first tap outside only puts it away, so a tap meant to dismiss the
    /// keyboard never closes the screen.
    @objc private func tappedOutside() {
        if panel.finishEditing() { return }
        leave()
    }

    override func accessibilityPerformEscape() -> Bool {
        if eyedropper != nil {
            endEyedropper()
        } else {
            leave()
        }
        return true
    }

    // MARK: Keyboard

    /// Moves the cards with a docked keyboard as it rises and falls. A floating or undocked keyboard
    /// leaves the bottom edge, and the layout keeps its place.
    @objc private func keyboardWillChange(_ notification: Notification) {
        guard isViewLoaded, let info = notification.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = view.convert(end, from: view.window?.screen.coordinateSpace ?? view)
        let docked = notification.name != UIResponder.keyboardWillHideNotification && frame.maxY >= view.bounds.maxY - 1
        let cover = docked ? max(view.bounds.maxY - frame.minY, 0) : 0
        guard cover != keyboardCover else { return }
        keyboardCover = cover
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? NotebookTheme.chromeFadeDuration
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        view.setNeedsLayout()
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let exit = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(exitCommand))
        exit.discoverabilityTitle = Self.exitLabel
        // Escape stays with the screen while a field is typed in, so it can put the keyboard away.
        exit.wantsPriorityOverSystemBehavior = true
        return [exit]
    }

    /// Escape steps back one level: out of the eyedropper, out of a field, then off the screen.
    @objc private func exitCommand() {
        if eyedropper != nil {
            endEyedropper()
        } else if !panel.finishEditing() {
            leave()
        }
    }

    /// The scratchpad's own history, so nothing inside the screen reaches the notebook's.
    override var undoManager: UndoManager? { scratchpad.canvas.undoManager }

    // Undo and redo stop here whether or not the scratchpad has history to step through, so the
    // notebook beneath never undoes while the screen is open.
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if action == #selector(undo(_:)) || action == #selector(redo(_:)) {
            return canPerformAction(action, withSender: sender) ? self : nil
        }
        return super.target(forAction: action, withSender: sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) { return undoManager?.canUndo ?? false }
        if action == #selector(redo(_:)) { return undoManager?.canRedo ?? false }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    // MARK: Trial

    /// Shows the trial as of now, and waits for the border to close if it is drawing.
    func refreshTrial() {
        let time = now()
        let phase = trial.phase(at: time)
        scratchpad.showTrial(trial, at: time, reduceMotion: prefersCrossFade())
        if phase != trialPhase {
            trialPhase = phase
            refreshExitHint()
        }
        let showsToast = trial.showsToast(at: time)
        if showsToast != isToastShown {
            isToastShown = showsToast
            if showsToast {
                showToast()
                UIAccessibility.post(notification: .announcement, argument: Self.selectedAnnouncement)
            } else {
                hideToast()
            }
        }
        trialTask?.cancel()
        guard phase == .trying, let retainsAt = trial.retainsAt else { return }
        let delay = max(retainsAt - time, 0)
        trialTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshTrial()
        }
    }

    private func updateTrial(_ change: (inout InkTrialTimeline, TimeInterval) -> Void) {
        guard !isClosing else { return }
        let before = trial
        change(&trial, now())
        if trial != before { refreshTrial() }
    }

    private func refreshExitHint() {
        exitHint.accessibilityHint = trialPhase == .retained ? Self.exitKeepsHint : Self.exitLeavesHint
    }

    // MARK: Toast

    private var toastSize: CGSize {
        toast.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: NotebookTheme.colorToastHeight))
    }

    /// Centred over the scratchpad, just above its frame.
    func toastFrame(over scratchpad: CGRect) -> CGRect {
        let size = toastSize
        return CGRect(
            x: scratchpad.midX - size.width / 2, y: scratchpad.minY - NotebookTheme.colorToastGap - size.height,
            width: size.width, height: size.height
        )
    }

    /// Where the border starts, at the top centre of the scratchpad, in the screen's coordinates.
    var borderStart: CGPoint {
        view.convert(scratchpad.border.startPoint, from: scratchpad.border)
    }

    /// The toast rises from where the border started and settles above it.
    private func showToast() {
        let host = toast.view!
        host.layer.removeAllAnimations()
        host.isHidden = false
        if prefersCrossFade() {
            host.transform = .identity
            host.alpha = 0
            UIView.animate(withDuration: NotebookTheme.chromeFadeDuration, delay: 0, options: [.curveLinear]) {
                host.alpha = 1
            }
        } else {
            let start = borderStart
            let scale = NotebookTheme.colorToastStartScale
            host.transform = CGAffineTransform(translationX: start.x - host.center.x, y: start.y - host.center.y)
                .scaledBy(x: scale, y: scale)
            host.alpha = 0
            UIView.animate(
                springDuration: NotebookTheme.colorToastEntranceDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                options: [.allowUserInteraction]
            ) {
                host.transform = .identity
                host.alpha = 1
            }
        }
        refreshAccessibilityOrder()
    }

    private func hideToast() {
        let host = toast.view!
        UIView.animate(
            withDuration: NotebookTheme.colorToastExitDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            host.alpha = 0
        } completion: { finished in
            if finished, !self.isToastShown { host.isHidden = true }
        }
        refreshAccessibilityOrder()
    }

    // MARK: Eyedropper

    /// Shows the picture of the page beneath with a loupe; lifting over it picks a colour.
    func startEyedropper() {
        guard eyedropper == nil, !isClosing, let snapshot else { return }
        panel.finishEditing()
        // Sized once: a change of size ends the eyedropper, as the picture fits only this one.
        let dropper = NotebookEyedropperView(snapshot: snapshot)
        dropper.frame = view.bounds
        dropper.onSample = { [weak self] color in self?.sampled(color) }
        dropper.onCancel = { [weak self] in self?.endEyedropper() }
        view.addSubview(dropper)
        eyedropper = dropper
        exitTap.isEnabled = false
        dropper.alpha = 0
        UIView.animate(withDuration: NotebookTheme.chromeFadeDuration) { dropper.alpha = 1 }
        refreshAccessibilityOrder()
        UIAccessibility.post(notification: .screenChanged, argument: dropper)
    }

    /// Returns from the eyedropper to the picker.
    func endEyedropper() {
        guard let dropper = eyedropper else { return }
        eyedropper = nil
        exitTap.isEnabled = !isClosing
        UIView.animate(withDuration: NotebookTheme.chromeFadeDuration) {
            dropper.alpha = 0
        } completion: { _ in
            dropper.removeFromSuperview()
        }
        refreshAccessibilityOrder()
        UIAccessibility.post(notification: .screenChanged, argument: panel.eyedropperKey)
    }

    private func sampled(_ rgb: EditorInkColor) {
        let next = EditorHSBColor(rgb, keepingHue: color.hue, saturation: color.saturation).with(alpha: color.alpha)
        endEyedropper()
        show(next, change: .settled)
    }

    /// Pictures the page beneath for the eyedropper, which is offered only once there is a picture.
    func capturePage() {
        snapshot = pageSource(self).flatMap(NotebookPageSnapshot.capture)
        panel.eyedropperKey.isEnabled = snapshot != nil
    }

    /// The notebook view under the toolbar this screen was opened from.
    private func notebookPage() -> UIView? {
        func notebook(in controller: UIViewController) -> NotebookViewController? {
            if let notebook = controller as? NotebookViewController, store.belongs(to: notebook) { return notebook }
            return controller.children.lazy.compactMap { notebook(in: $0) }.first
        }
        guard let root = presentingViewController?.view.window?.rootViewController else { return nil }
        return notebook(in: root)?.view
    }

    // MARK: Motion

    /// The screen fades in over the notebook as the shade bar rises from the bottom edge.
    func enter() {
        let reduceMotion = prefersCrossFade()
        view.layoutIfNeeded()
        view.alpha = 0
        UIView.animate(withDuration: NotebookTheme.colorScreenEntranceDuration, delay: 0, options: [.curveEaseOut]) {
            self.view.alpha = 1
        }
        guard !reduceMotion else { return }
        shadeBar.transform = CGAffineTransform(translationX: 0, y: shadeBar.bounds.height)
        UIView.animate(
            springDuration: NotebookTheme.shadeBarEntranceDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
            options: [.allowUserInteraction]
        ) {
            self.shadeBar.transform = .identity
        }
    }

    private func showScratchpad() {
        guard !showsScratchpad, isViewLoaded else { return }
        // Where the panel shows now, read before a layout still pending can place it aside.
        let start = panel.center
        showsScratchpad = true
        setScratchpadReachable(true)
        view.layoutIfNeeded()
        guard let layout else { return }
        let target = layout.pickerFrame(showingScratchpad: true)
        if prefersCrossFade() {
            fadeToScratchpad(from: start, to: target)
        } else {
            place(panel, in: target)
            let entry = layout.scratchpadEntryOffset
            panel.transform = CGAffineTransform(translationX: start.x - panel.center.x, y: start.y - panel.center.y)
            scratchpad.view.transform = CGAffineTransform(translationX: entry.dx, y: entry.dy)
            UIView.animate(
                springDuration: NotebookTheme.colorScreenGlideDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.panel.transform = .identity
                self.scratchpad.view.transform = .identity
                self.scratchpad.view.alpha = 1
            }
        }
        refreshAccessibilityOrder()
        // VoiceOver keeps its place in the panel and learns of the scratchpad beside it.
        UIAccessibility.post(
            notification: .layoutChanged, argument: UIAccessibility.focusedElement(using: .notificationVoiceOver)
        )
    }

    /// The Reduce Motion form of the glide. The panel fades out where it is, steps to its new place
    /// while unseen and fades back in as the scratchpad appears, so nothing moves and it never
    /// shows in two places at once. Each part runs on the render server alone.
    private func fadeToScratchpad(from start: CGPoint, to target: CGRect) {
        let duration = NotebookTheme.colorScreenFadeDuration
        place(panel, in: target)
        scratchpad.view.alpha = 1

        let step = CAKeyframeAnimation(keyPath: "position")
        step.values = [start, panel.layer.position].map { NSValue(cgPoint: $0) }
        step.keyTimes = [0, 0.5, 1]
        step.calculationMode = .discrete
        step.duration = duration
        panel.layer.add(step, forKey: Self.fadeStepKey)

        let dip = CAKeyframeAnimation(keyPath: "opacity")
        dip.values = [1, 0, 1]
        dip.keyTimes = [0, 0.5, 1]
        dip.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        dip.duration = duration
        panel.layer.add(dip, forKey: Self.fadeKey)

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        appear.beginTime = scratchpad.view.layer.convertTime(CACurrentMediaTime(), from: nil) + duration / 2
        appear.duration = duration / 2
        appear.fillMode = .backwards
        scratchpad.view.layer.add(appear, forKey: Self.fadeKey)
    }

    private func setScratchpadReachable(_ reachable: Bool) {
        scratchpad.view.isUserInteractionEnabled = reachable
        scratchpad.view.accessibilityElementsHidden = !reachable
    }

    /// Read in this order: the panel, the scratchpad and its toast once they show, the shades, then
    /// the way out. The eyedropper, while open, stands alone.
    private func refreshAccessibilityOrder() {
        if let eyedropper {
            view.accessibilityElements = [eyedropper]
            return
        }
        var elements: [Any] = [panel]
        if showsScratchpad { elements.append(scratchpad.view as Any) }
        if isToastShown, let host = toast.view { elements.append(host) }
        elements += [shadeBar, exitHint]
        view.accessibilityElements = elements
    }

    /// Sets size and position apart from the transform, which a glide may still be animating.
    private func place(_ child: UIView, in frame: CGRect) {
        child.bounds.size = frame.size
        child.center = CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// The quiet line under the cards. It reads as a hint, yet VoiceOver offers it as the screen's
/// way out, saying what leaving would do.
@MainActor
final class NotebookColorScreenExitHint: UILabel {
    static let message = "Tap anywhere to exit"

    var onActivate: (@MainActor () -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        text = Self.message
        font = UIFont.preferredFont(forTextStyle: .footnote)
        adjustsFontForContentSizeCategory = true
        // 5.2:1 on the stone: quiet, yet readable.
        textColor = NotebookTheme.glyphSecondary.uiColor
        textAlignment = .center
        numberOfLines = 0
        isAccessibilityElement = true
        accessibilityLabel = NotebookColorPickerScreenController.exitLabel
        // Voice Control answers to the words on screen as well as the short name.
        accessibilityUserInputLabels = [NotebookColorPickerScreenController.exitLabel, Self.message]
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// The pill that confirms the colour is kept, in the shell's material with the editor's type.
struct NotebookColorSelectedToast: View {
    static let title = "Color Selected"

    var body: some View {
        HStack(spacing: NotebookTheme.colorToastSpacing) {
            Image(systemName: "checkmark")
                .font(.system(size: NotebookTheme.swatchCheckmarkSize, weight: .bold))
                .foregroundStyle(NotebookTheme.colorToastCheck.color)
            Text(Self.title)
                .notebookTypeface(NotebookTheme.colorToastLabel)
                .foregroundStyle(NotebookTheme.glyph.color)
                .lineLimit(1)
        }
        .padding(.horizontal, NotebookTheme.colorToastPadding)
        .frame(height: NotebookTheme.colorToastHeight)
        .background { NotebookPanelShell(cornerRadius: NotebookTheme.colorToastHeight / 2) }
        .fixedSize()
        // The pill keeps its height, so its words grow only so far.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NotebookColorPickerScreenController.selectedAnnouncement)
    }
}

// MARK: - Scratchpad

/// A sheet of the notebook's paper in a dark frame, where the chosen ink can be tried. The frame
/// holds the caption with the trial's status, the Clear key and the border that draws itself
/// around the sheet. It draws with the ink leaving would apply. Its strokes are never saved and
/// keep their own undo history, apart from the notebook's.
@MainActor
final class NotebookScratchpadController: UIViewController, PKCanvasViewDelegate {
    static let caption = "Try your ink"
    static let canvasLabel = "Scratchpad"
    static let canvasHint = "Draw here to try the ink. Nothing drawn here is saved."
    static let clearTitle = "Clear"
    static let clearHint = "Erases what you drew on the scratchpad."
    static let tryingStatus = "Trying…"
    static let readyStatus = "Ready"

    let canvas = NotebookScratchpadCanvas()
    let paper = NotebookScratchpadPaper()
    let border = NotebookTrialBorder()
    let captionLabel = UILabel()
    let statusGlyph = UIImageView()
    let statusLabel = UILabel()
    let clearKey = NotebookColorPanelKey(title: NotebookScratchpadController.clearTitle)
    /// Told when a stroke begins, the scratchpad's first sign of use.
    var onBeginStroke: (@MainActor () -> Void)?
    /// The ink the scratchpad draws with.
    var ink: EditorToolState? {
        didSet {
            guard let ink, ink != oldValue else { return }
            canvas.tool = ink.nativeTool
        }
    }
    /// The zoom the notebook shows its page at. Ink widths are in page points, so the paper takes
    /// the same zoom for a stroke to look as wide as it will on the page.
    var pageScale: CGFloat = 1 {
        didSet {
            if pageScale != oldValue, isViewLoaded { view.setNeedsLayout() }
        }
    }
    var phase: InkTrialTimeline.Phase { border.phase }

    override func loadView() {
        view = UIView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NotebookTheme.colorPanelFill.uiColor
        view.layer.cornerRadius = NotebookTheme.panelCornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = NotebookTheme.shellBorderWidth
        view.layer.shadowColor = NotebookTheme.shadowTone.uiColor.cgColor
        view.layer.shadowOpacity = Float(NotebookTheme.shellShadow.opacity)
        view.layer.shadowRadius = NotebookTheme.shellShadow.radius
        view.layer.shadowOffset = NotebookTheme.shellShadow.offset
        view.accessibilityContainerType = .semanticGroup

        captionLabel.textColor = NotebookTheme.colorPanelLabel.uiColor
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.accessibilityTraits = .header
        statusGlyph.contentMode = .center
        statusGlyph.isAccessibilityElement = false
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.isAccessibilityElement = false
        clearKey.accessibilityHint = Self.clearHint
        clearKey.isEnabled = false
        clearKey.addAction(UIAction { [weak self] _ in self?.clear() }, for: .touchUpInside)

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.bouncesZoom = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.isRulerActive = false
        // The same input as the notebook's paper: Apple Pencil on an iPad, any touch in Simulator.
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = Self.canvasLabel
        canvas.accessibilityHint = Self.canvasHint
        canvas.accessibilityTraits = .allowsDirectInteraction
        paper.addSubview(canvas)
        for part: UIView in [paper, captionLabel, statusGlyph, statusLabel, clearKey, border] {
            view.addSubview(part)
        }
        view.accessibilityElements = [captionLabel, clearKey, canvas]
        applyTypefaces()
        applyEdge()
        refreshStatus()
        registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self, UITraitAccessibilityContrast.self]
        ) { (controller: NotebookScratchpadController, _: UITraitCollection) in
            controller.applyTypefaces()
            controller.applyEdge()
            controller.view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let inset = NotebookTheme.scratchpadPaperInset
        border.frame = bounds
        let key = clearKey.intrinsicContentSize
        clearKey.frame = CGRect(x: bounds.maxX - inset - key.width, y: inset, width: key.width, height: key.height)
        let captionLeft = inset + NotebookTheme.scratchpadCaptionPadding
        let captionSize = captionLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: key.height))
        captionLabel.frame = CGRect(
            x: captionLeft, y: inset + (key.height - captionSize.height) / 2, width: captionSize.width, height: captionSize.height
        )
        let glyph = statusGlyph.intrinsicContentSize
        let statusLeft = captionLabel.frame.maxX + NotebookTheme.trialStatusSpacing
        statusGlyph.frame = CGRect(
            x: statusLeft, y: inset + (key.height - glyph.height) / 2, width: glyph.width, height: glyph.height
        )
        let statusSize = statusLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: key.height))
        let wordLeft = statusGlyph.frame.maxX + NotebookTheme.trialStatusGlyphSpacing
        statusLabel.frame = CGRect(
            x: wordLeft, y: inset + (key.height - statusSize.height) / 2,
            width: max(min(statusSize.width, clearKey.frame.minX - inset - wordLeft), 0), height: statusSize.height
        )

        let paperTop = inset + key.height + inset
        paper.frame = CGRect(
            x: inset, y: paperTop, width: max(bounds.width - 2 * inset, 0), height: max(bounds.height - paperTop - inset, 0)
        )
        canvas.frame = paper.bounds
        let scale = max(pageScale, 0.001)
        canvas.minimumZoomScale = scale
        canvas.maximumZoomScale = scale
        canvas.setZoomScale(scale, animated: false)
        // The drawable area is the visible sheet, at whatever zoom.
        canvas.contentSize = canvas.bounds.size
        canvas.contentOffset = .zero
        view.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: NotebookTheme.panelCornerRadius).cgPath
    }

    /// Erases the test strokes and their history. The trial goes on: the colour has been seen.
    func clear() {
        canvas.drawing = PKDrawing()
        canvas.undoManager?.removeAllActions()
        clearKey.isEnabled = false
    }

    /// Shows the trial as of `now`: the border and the status beside the caption.
    func showTrial(_ trial: InkTrialTimeline, at now: TimeInterval, reduceMotion: Bool) {
        let before = border.phase
        border.show(trial, at: now, reduceMotion: reduceMotion)
        if border.phase != before { refreshStatus() }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        onBeginStroke?()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        clearKey.isEnabled = !canvas.drawing.strokes.isEmpty
    }

    /// The word and glyph beside the caption, so the state never rests on the border's colour alone.
    private func refreshStatus() {
        let status: (word: String, glyph: String, tone: NotebookTheme.Tone)? = switch border.phase {
        case .untried: nil
        case .trying: (Self.tryingStatus, "hourglass", NotebookTheme.trialTryingMark)
        case .retained: (Self.readyStatus, "checkmark.circle.fill", NotebookTheme.trialReadyMark)
        }
        statusGlyph.isHidden = status == nil
        statusLabel.isHidden = status == nil
        if let status {
            let typeface = NotebookTheme.sectionLabel
            statusLabel.attributedText = NSAttributedString(
                string: status.word.uppercased(), attributes: [.kern: typeface.tracking, .font: typeface.scaledFont()]
            )
            statusLabel.textColor = status.tone.uiColor
            statusGlyph.image = UIImage(systemName: status.glyph)
            statusGlyph.tintColor = status.tone.uiColor
        }
        captionLabel.accessibilityValue = status?.word
        canvas.accessibilityValue = status?.word
        view.setNeedsLayout()
    }

    private func applyTypefaces() {
        let typeface = NotebookTheme.sectionLabel
        captionLabel.attributedText = NSAttributedString(
            string: Self.caption.uppercased(), attributes: [.kern: typeface.tracking, .font: typeface.scaledFont()]
        )
        captionLabel.accessibilityLabel = Self.caption
        statusGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: typeface.scaledFont())
        refreshStatus()
    }

    private func applyEdge() {
        view.layer.borderColor = NotebookTheme.colorPanelEdge.cgColor(for: traitCollection)
    }
}

/// The border that draws itself around the scratchpad: nothing before the first stroke, then a
/// yellow line from the top centre, clockwise, closing as the hold ends, when it turns green.
/// The drawing runs on the render server as one animation, so it costs nothing per frame.
@MainActor
final class NotebookTrialBorder: UIView {
    static let drawKey = "draw"
    static let turnKey = "turn"
    static let fadeKey = "fade"

    let stroke = CAShapeLayer()
    private(set) var phase = InkTrialTimeline.Phase.untried
    /// The start of the trial the border shows, so a restart is told from a refresh.
    private var startedAt: TimeInterval?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        stroke.fillColor = nil
        stroke.lineWidth = NotebookTheme.trialBorderWidth
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.strokeEnd = 0
        layer.addSublayer(stroke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    /// The line's course: the frame inset to the middle of the band around the paper.
    var course: CGRect {
        bounds.insetBy(dx: NotebookTheme.trialBorderInset, dy: NotebookTheme.trialBorderInset)
    }

    /// Where the line starts, the top centre of its course.
    var startPoint: CGPoint {
        CGPoint(x: course.midX, y: course.minY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutAnimations {
            stroke.frame = bounds
            stroke.path = Self.path(around: course, cornerRadius: NotebookTheme.panelCornerRadius - NotebookTheme.trialBorderInset)
        }
    }

    /// A rounded rectangle that begins at the top centre and runs clockwise back to it, so the
    /// stroke's end traces the trial's progress.
    static func path(around rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let radius = max(min(cornerRadius, rect.width / 2, rect.height / 2), 0)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }

    /// Shows `trial` as of `now`. A trial started again draws from the top centre once more.
    func show(_ trial: InkTrialTimeline, at now: TimeInterval, reduceMotion: Bool) {
        let phase = trial.phase(at: now)
        let restarted = trial.startedAt != startedAt
        let previous = self.phase
        startedAt = trial.startedAt
        self.phase = phase
        let traits = traitCollection
        switch phase {
        case .untried:
            stroke.removeAllAnimations()
            withoutAnimations { stroke.strokeEnd = 0 }
        case .trying:
            guard restarted || previous != .trying else { return }
            stroke.removeAllAnimations()
            let progress = trial.borderProgress(at: now, reduceMotion: reduceMotion)
            withoutAnimations {
                stroke.strokeColor = NotebookTheme.trialTryingBorder.cgColor(for: traits)
                stroke.strokeEnd = 1
            }
            if progress < 1 {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = progress
                draw.toValue = 1
                draw.duration = (1 - progress) * InkTrialTimeline.holdDuration
                draw.timingFunction = CAMediaTimingFunction(name: .linear)
                stroke.add(draw, forKey: Self.drawKey)
            } else if previous == .untried {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = NotebookTheme.chromeFadeDuration
                stroke.add(fade, forKey: Self.fadeKey)
            }
        case .retained:
            guard previous != .retained else { return }
            stroke.removeAnimation(forKey: Self.drawKey)
            let turn = CABasicAnimation(keyPath: "strokeColor")
            turn.fromValue = NotebookTheme.trialTryingBorder.cgColor(for: traits)
            turn.toValue = NotebookTheme.trialReadyBorder.cgColor(for: traits)
            turn.duration = NotebookTheme.trialBorderTurnDuration
            turn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            withoutAnimations {
                stroke.strokeColor = NotebookTheme.trialReadyBorder.cgColor(for: traits)
                stroke.strokeEnd = 1
            }
            stroke.add(turn, forKey: Self.turnKey)
        }
    }
}

/// The scratchpad's canvas. The window's shared undo manager carries the notebook's history, so
/// this canvas keeps its own and test strokes never reach the notebook's.
@MainActor
final class NotebookScratchpadCanvas: PKCanvasView {
    private let history = UndoManager()

    override var undoManager: UndoManager? { history }
}

/// A sheet of the notebook's paper: its ivory, its fibre tile, which plain materials hide as
/// they do on the page, and its edge, a dark line under Increase Contrast.
@MainActor
final class NotebookScratchpadPaper: UIView {
    let grainLayer = CALayer()
    private let accessibility: NotebookMaterialAccessibility

    init(materials: NotebookMaterials = .shared, accessibility: NotebookMaterialAccessibility = .system) {
        self.accessibility = accessibility
        super.init(frame: .zero)
        backgroundColor = NotebookTheme.paperIvory.uiColor
        isOpaque = true
        clipsToBounds = true
        layer.cornerRadius = NotebookTheme.scratchpadPaperCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = NotebookTheme.shellBorderWidth
        grainLayer.isHidden = accessibility.prefersPlainMaterials
        layer.addSublayer(grainLayer)
        applyEdgeTone()
        registerForTraitChanges(
            [UITraitAccessibilityContrast.self]
        ) { (paper: NotebookScratchpadPaper, _: UITraitCollection) in
            paper.applyEdgeTone()
        }
        materials.whenReady { [weak self] materials in
            withoutAnimations { self?.grainLayer.backgroundColor = materials.paperFibrePattern }
        }
        for name in NotebookMaterialAccessibility.statusChangeNotifications {
            accessibility.notificationCenter.addObserver(
                self, selector: #selector(accessibilityMaterialsChanged), name: name, object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(materials:accessibility:).")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutAnimations { grainLayer.frame = bounds }
    }

    private func applyEdgeTone() {
        layer.borderColor = NotebookTheme.paperEdge.cgColor(for: traitCollection)
    }

    @objc private func accessibilityMaterialsChanged() {
        withoutAnimations { grainLayer.isHidden = accessibility.prefersPlainMaterials }
    }
}
