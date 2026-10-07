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
    /// True while the owning canvas has a stroke or other tool use in progress. Not published,
    /// so a pen going down or up never invalidates the toolbar's controls.
    private(set) var isToolActive = false
    /// How far the toolbar reaches in from the top or bottom of the control area, the canvas
    /// less its chrome. The canvas it is drawn over adds it to the chrome as scroll space,
    /// whether or not it owns the tools, so no page end stays covered. It is handed to the
    /// canvas directly; no view draws it, so it is not published.
    private(set) var overlayObstruction = UIEdgeInsets.zero

    let toolDefaultsKey: String
    private let defaults: UserDefaults
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
        isToolActive = false
    }

    func setToolbarAvailable(_ available: Bool, for controller: NotebookViewController) {
        guard activeController === controller, isToolbarAvailable != available else { return }
        isToolbarAvailable = available
    }

    func setToolActive(_ active: Bool, for controller: NotebookViewController) {
        guard activeController === controller else { return }
        isToolActive = active
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

    /// Brings hidden tools back, as a tap on the reveal tab or a Pencil gesture asks.
    func revealTools() {
        setToolsHidden(false)
    }

    /// Stores settled toolbar preferences. Callers pass final drag results, not every frame.
    func updateToolbar(_ preferences: EditorToolbarPreferences) {
        guard preferences != toolbar else { return }
        toolbar = preferences
        defaults.set(preferences.encoded(), forKey: Self.toolbarDefaultsKey)
    }

    func handlePencil(_ preference: EditorPencilTapPreference, from controller: NotebookViewController) {
        guard activeController === controller, isToolbarAvailable else { return }
        var reveal = false
        update { reveal = $0.handlePencilDoubleTap(preference) }
        if reveal { revealRequest &+= 1 }
    }
}
