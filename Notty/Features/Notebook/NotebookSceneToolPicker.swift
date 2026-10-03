import Foundation
import PencilKit
import UIKit

@MainActor
final class NotebookSceneToolPicker {
    private static let owners = NSMapTable<UIWindowScene, NotebookSceneToolPicker>.weakToStrongObjects()
    private(set) static var creationCount = 0

    let picker: PKToolPicker
    private weak var activeController: NotebookViewController?

    private init(scene: UIWindowScene) {
        let pen = PKToolPickerInkingItem(
            type: .pen, color: UIColor(red: 0.19, green: 0.16, blue: 0.13, alpha: 1),
            width: 3, identifier: "notty.pen"
        )
        let otherItems = PKToolPicker.defaultToolItems.filter { item in
            guard let ink = item as? PKToolPickerInkingItem else { return true }
            return ink.inkingTool.inkType != .pen
        }
        picker = PKToolPicker(toolItems: [pen] + otherItems)
        picker.stateAutosaveName = "notty.palette." + scene.session.persistentIdentifier
        picker.showsDrawingPolicyControls = false
        Self.creationCount += 1
    }

    static func owner(for scene: UIWindowScene) -> NotebookSceneToolPicker {
        if let owner = owners.object(forKey: scene) { return owner }
        let owner = NotebookSceneToolPicker(scene: scene)
        owners.setObject(owner, forKey: scene)
        return owner
    }

    func attach(_ controller: NotebookViewController) {
        if let previous = activeController, previous !== controller {
            previous.tearDown()
        }
        activeController = controller
        picker.addObserver(controller.canvasView)
        picker.addObserver(controller)
    }

    func belongs(to controller: NotebookViewController) -> Bool {
        activeController === controller
    }

    func detach(_ controller: NotebookViewController) {
        guard activeController === controller else { return }
        picker.setVisible(false, forFirstResponder: controller.canvasView)
        picker.removeObserver(controller.canvasView)
        picker.removeObserver(controller)
        activeController = nil
    }
}
