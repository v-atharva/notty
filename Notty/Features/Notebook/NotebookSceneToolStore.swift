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
    /// Publishes tool use apart from the store, so a pen going down or up invalidates only the
    /// views that wait for it, never the toolbar's controls.
    let activity = NotebookToolActivity()
    /// How far a floating toolbar reaches in from each canvas edge, in canvas points. The
    /// owning canvas adds the top and bottom as scrollable space so no page end stays covered.
    /// It is handed to the canvas directly; no view draws it, so it is not published.
    private(set) var overlayObstruction = UIEdgeInsets.zero

    let toolDefaultsKey: String
    private let defaults: UserDefaults
    private weak var activeController: NotebookViewController?

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

    /// True while the owning canvas has a stroke or other tool use in progress. Layout
    /// changes that would move the canvas wait until it ends.
    var isToolActive: Bool { activity.isToolActive }

    func belongs(to controller: NotebookViewController) -> Bool {
        activeController === controller
    }

    func detach(_ controller: NotebookViewController) {
        guard activeController === controller else { return }
        activeController = nil
        resetOwnerState()
    }

    /// Assigns only real changes, so observing toolbar views are not invalidated for nothing.
    private func resetOwnerState() {
        if isToolbarAvailable { isToolbarAvailable = false }
        if activity.isToolActive { activity.isToolActive = false }
    }

    func setToolbarAvailable(_ available: Bool, for controller: NotebookViewController) {
        guard activeController === controller, isToolbarAvailable != available else { return }
        isToolbarAvailable = available
    }

    func setToolActive(_ active: Bool, for controller: NotebookViewController) {
        guard activeController === controller, activity.isToolActive != active else { return }
        activity.isToolActive = active
    }

    func setOverlayObstruction(_ insets: UIEdgeInsets) {
        guard insets != overlayObstruction else { return }
        overlayObstruction = insets
        activeController?.applyOverlayObstruction()
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

/// Whether the owning canvas has a stroke or other tool use in progress.
@MainActor
final class NotebookToolActivity: ObservableObject {
    @Published fileprivate(set) var isToolActive = false
}
