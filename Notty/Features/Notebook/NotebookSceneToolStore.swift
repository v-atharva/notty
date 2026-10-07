import Foundation
import NottyCore
import UIKit

/// Scene-scoped drawing tool selection and toolbar preferences. One notebook
/// controller owns it at a time; replacing the notebook keeps the selected tool
/// and retires the previous controller.
@MainActor
final class NotebookSceneToolStore: ObservableObject {
    static let toolbarDefaultsKey = "notty.editor.toolbar"
    /// The tool last chosen in any scene, used to seed a scene with no stored tool.
    static let lastToolDefaultsKey = "notty.editor.tool.last"
    private static let sceneToolKeyPrefix = "notty.editor.tool."
    private static let owners = NSMapTable<UIWindowScene, NotebookSceneToolStore>.weakToStrongObjects()
    private(set) static var creationCount = 0

    @Published private(set) var tool: EditorToolState
    @Published private(set) var toolbar: EditorToolbarPreferences
    /// True only while the owning canvas admits tool choices.
    @Published private(set) var isToolbarAvailable = false
    /// Incremented when an Apple Pencil gesture asks for the tools to be shown.
    @Published private(set) var revealRequest: UInt64 = 0
    /// True while the writing view keeps the tools out of sight. The toolbar keeps its
    /// placement and preferences; only whether it shows changes.
    @Published private(set) var areToolsHidden = false
    /// True while the rail shows its second row, the presets and colours of the ink in use. The row
    /// opens only at the user's request, so it is not stored: every launch shows the first row alone.
    @Published private(set) var isInkRowOpen = false
    /// How far the toolbar reaches in from the top or bottom of the control area, the canvas
    /// less its chrome. The canvas it is drawn over adds it to the chrome as scroll space,
    /// whether or not it owns the tools, so no page end stays covered. It is handed to the
    /// canvas directly; no view draws it, so it is not published.
    private(set) var overlayObstruction = UIEdgeInsets.zero

    let toolDefaultsKey: String
    private let defaults: UserDefaults
    /// The writing view of the notebook shown in this scene, which decides when the tools show.
    private weak var writingChrome: NotebookWritingChrome?
    private weak var activeController: NotebookViewController?
    /// The canvas the toolbar is drawn over. A paused canvas never owns the tools, yet the
    /// toolbar still covers its first lines.
    private weak var coveredController: NotebookViewController?

    init(identifier: String, defaults: UserDefaults) {
        self.defaults = defaults
        toolDefaultsKey = Self.sceneToolKeyPrefix + identifier
        let stored = defaults.data(forKey: toolDefaultsKey) ?? defaults.data(forKey: Self.lastToolDefaultsKey)
        tool = EditorToolState.decode(stored)
        toolbar = EditorToolbarPreferences.decode(defaults.data(forKey: Self.toolbarDefaultsKey))
        Self.creationCount += 1
    }

    static func owner(for scene: UIWindowScene, defaults: UserDefaults = .standard) -> NotebookSceneToolStore {
        if let owner = owners.object(forKey: scene) { return owner }
        let openSessions = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        pruneStoredTools(in: defaults, keepingSessions: openSessions)
        let owner = NotebookSceneToolStore(identifier: scene.session.persistentIdentifier, defaults: defaults)
        owners.setObject(owner, forKey: scene)
        return owner
    }

    func attach(_ controller: NotebookViewController) {
        if let previous = activeController, previous !== controller {
            previous.tearDown()
        }
        activeController = controller
        resetOwnerState()
    }

    func belongs(to controller: NotebookViewController) -> Bool {
        activeController === controller
    }

    func detach(_ controller: NotebookViewController) {
        guard activeController === controller else { return }
        activeController = nil
        resetOwnerState()
    }

    /// Records the canvas shown under the toolbar, which reserves the toolbar's obstruction.
    func cover(_ controller: NotebookViewController) {
        coveredController = controller
    }

    func uncover(_ controller: NotebookViewController) {
        guard coveredController === controller else { return }
        coveredController = nil
    }

    func covers(_ controller: NotebookViewController) -> Bool {
        coveredController === controller
    }

    /// Clears what the previous owner reported. Availability is published, so it is assigned
    /// only when it changes and the toolbar's views are not invalidated for nothing.
    private func resetOwnerState() {
        if isToolbarAvailable { isToolbarAvailable = false }
    }

    func setToolbarAvailable(_ available: Bool, for controller: NotebookViewController) {
        guard activeController === controller, isToolbarAvailable != available else { return }
        isToolbarAvailable = available
    }

    /// - Parameter followingResize: true when the toolbar was re-measured because the control
    ///   area changed size, not because the toolbar moved.
    func setOverlayObstruction(_ insets: UIEdgeInsets, followingResize: Bool = false) {
        guard insets != overlayObstruction else { return }
        overlayObstruction = insets
        activeController?.applyOverlayObstruction(followingResize: followingResize)
        if coveredController !== activeController {
            coveredController?.applyOverlayObstruction(followingResize: followingResize)
        }
    }

    /// Removes tools stored for scene sessions that no longer exist, keeping the last choice
    /// that seeds new scenes.
    static func pruneStoredTools(in defaults: UserDefaults, keepingSessions identifiers: Set<String>) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(sceneToolKeyPrefix) && key != lastToolDefaultsKey
            && !identifiers.contains(String(key.dropFirst(sceneToolKeyPrefix.count))) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Changes the selection, stores it, and hands it to the owning canvas, which
    /// defers it while a stroke is in progress.
    func update(_ change: (inout EditorToolState) -> Void) {
        var next = tool
        change(&next)
        guard next != tool else { return }
        tool = next
        let data = next.encoded()
        defaults.set(data, forKey: toolDefaultsKey)
        defaults.set(data, forKey: Self.lastToolDefaultsKey)
        activeController?.applyTool(next)
    }

    /// Shows or hides the tools. Only a real change is published, so repeated requests from
    /// scrolling or pen-up never invalidate the toolbar.
    func setToolsHidden(_ hidden: Bool) {
        guard areToolsHidden != hidden else { return }
        areToolsHidden = hidden
    }

    /// Opens or closes the rail's second row. Only a real change is published.
    func setInkRowOpen(_ open: Bool) {
        guard isInkRowOpen != open else { return }
        isInkRowOpen = open
    }

    /// Asks for hidden tools back, as the reveal tab and the other stand-ins do. The writing view
    /// of the notebook shown in this scene decides: it brings the header back with the tools, to
    /// stay until the next hide, and holds the request while a stroke is in progress. Without a
    /// writing view the tools return at once, alone.
    func revealTools() {
        guard let writingChrome else {
            setToolsHidden(false)
            return
        }
        writingChrome.reveal(.sticky)
    }

    /// Chooses and stores the writing view, as the stand-ins for hidden tools offer to. The writing
    /// view of the notebook shown in this scene adopts it; without one only the preference changes.
    func chooseWritingView(_ mode: EditorChromeMode) {
        guard let writingChrome else {
            var preferences = toolbar
            preferences.setChromeMode(mode)
            updateToolbar(preferences)
            return
        }
        writingChrome.setMode(mode)
    }

    /// Hands the writing view of the notebook now shown in this scene its reveal requests.
    func adoptWritingChrome(_ chrome: NotebookWritingChrome) {
        writingChrome = chrome
    }

    /// Whether `chrome` is the writing view this scene's tools follow.
    func isWritingChrome(_ chrome: NotebookWritingChrome) -> Bool {
        writingChrome === chrome
    }

    /// Reported by the toolbar's drag from its first move to its end, so the toolbar and header
    /// never hide mid-drag.
    func setToolbarDragging(_ dragging: Bool) {
        writingChrome?.setToolbarDragging(dragging)
    }

    /// Reported by the toolbar while one of its popovers or sheets, identified by `id`, is open,
    /// so the tools and header stay in sight and Escape is left to close it.
    func setToolbarPresentation(_ id: UUID, isPresented: Bool) {
        writingChrome?.setPresentation(id, isPresented: isPresented)
    }

    /// Stores settled toolbar preferences. Callers pass final drag results, not every frame.
    func updateToolbar(_ preferences: EditorToolbarPreferences) {
        guard preferences != toolbar else { return }
        toolbar = preferences
        defaults.set(preferences.encoded(), forKey: Self.toolbarDefaultsKey)
    }

    /// A gesture that asks for the palette brings the tools up to stay. One that switches the tool
    /// shows them briefly, so the change is seen while the writing view keeps the page clear.
    func handlePencil(_ preference: EditorPencilTapPreference, from controller: NotebookViewController) {
        guard activeController === controller, isToolbarAvailable else { return }
        var reveal = false
        let before = tool
        update { reveal = $0.handlePencilDoubleTap(preference) }
        if reveal {
            revealRequest &+= 1
            writingChrome?.reveal(.sticky)
        } else if tool != before {
            writingChrome?.reveal(.transient)
        }
    }
}
