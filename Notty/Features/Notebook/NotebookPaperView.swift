import QuartzCore
import UIKit

@MainActor
class NotebookPaperView: UIView {
    static var paperColor: UIColor { NotebookTheme.paperIvory.uiColor }

    /// Leather around the page. Its pattern is anchored to the window, so it continues the
    /// leather bands above the canvas without a seam.
    let leatherLayer = CALayer()
    let contentLayer = CALayer()
    /// Paper fibres under the dividers and the edge. It repeats a cached tile and moves with
    /// `contentLayer`, so scrolling and zooming never redraw it.
    let grainLayer = CALayer()
    let edgeLayer = CALayer()
    private(set) var boundaryLayers: [CALayer] = []
    private(set) var geometryUpdates = 0
    private(set) var viewportUpdates = 0
    private(set) var thicknessUpdates = 0

    private var logicalWidth: CGFloat = 0
    private var logicalHeight: CGFloat = 0
    private var boundaries: [CGFloat] = []
    private var viewportScale: CGFloat = 1
    private var viewportOffset = CGPoint.zero
    private let accessibility: NotebookMaterialAccessibility

    init(
        frame: CGRect, materials: NotebookMaterials = .shared,
        accessibility: NotebookMaterialAccessibility = .system
    ) {
        self.accessibility = accessibility
        super.init(frame: frame)
        // Leather is the desk around the page. PencilKit draws finished ink only over the page,
        // so no stroke rests on the leather. Flat until the tile is ready.
        backgroundColor = NotebookTheme.leatherMid.uiColor
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        // Core Animation draws pattern colours upside down relative to the tile image.
        leatherLayer.transform = CATransform3DMakeScale(1, -1, 1)
        leatherLayer.isHidden = accessibility.prefersPlainMaterials
        layer.addSublayer(leatherLayer)
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        contentLayer.backgroundColor = Self.paperColor.cgColor
        grainLayer.anchorPoint = .zero
        grainLayer.position = .zero
        grainLayer.isHidden = accessibility.prefersPlainMaterials
        contentLayer.addSublayer(grainLayer)
        edgeLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        edgeLayer.backgroundColor = NotebookTheme.paperEdge.cgColor
        contentLayer.addSublayer(edgeLayer)
        layer.addSublayer(contentLayer)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: NotebookPaperView, _: UITraitCollection) in
            view.finishZoom()
        }
        // Tiles render off the main thread, so opening a notebook never waits for them; the
        // textures appear once, when they are ready.
        materials.whenReady { [weak self] materials in
            self?.applyMaterials(materials)
        }
        for name in NotebookMaterialAccessibility.statusChangeNotifications {
            accessibility.notificationCenter.addObserver(
                self, selector: #selector(accessibilityMaterialsChanged), name: name, object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLeatherPhase()
        finishZoom()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLeatherPhase()
    }

    func setGeometry(width: CGFloat, height: CGFloat, boundaries: [CGFloat]) {
        guard width != logicalWidth || height != logicalHeight || boundaries != self.boundaries else { return }
        logicalWidth = width
        logicalHeight = height
        self.boundaries = boundaries
        geometryUpdates += 1
        withoutAnimations {
            while boundaryLayers.count > boundaries.count {
                boundaryLayers.removeLast().removeFromSuperlayer()
            }
            while boundaryLayers.count < boundaries.count {
                let divider = CALayer()
                divider.anchorPoint = CGPoint(x: 0, y: 0.5)
                divider.backgroundColor = NotebookTheme.paperDivider.cgColor
                contentLayer.addSublayer(divider)
                boundaryLayers.append(divider)
            }
            contentLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            grainLayer.bounds = contentLayer.bounds
            for (divider, y) in zip(boundaryLayers, boundaries) {
                divider.position = CGPoint(x: 0, y: y)
            }
            edgeLayer.position = CGPoint(x: 0, y: height)
            edgeLayer.isHidden = height <= 0
        }
        finishZoom()
    }

    func setViewport(scale: CGFloat, offset: CGPoint) {
        guard scale.isFinite, scale > 0, offset.x.isFinite, offset.y.isFinite,
              scale != viewportScale || offset != viewportOffset else { return }
        viewportScale = scale
        viewportOffset = offset
        viewportUpdates += 1
        withoutAnimations {
            contentLayer.transform = CATransform3DMakeAffineTransform(
                CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: -offset.x, ty: -offset.y)
            )
        }
    }

    func finishZoom() {
        let screenScale = max(traitCollection.displayScale, 1)
        let thickness = 1 / (screenScale * viewportScale)
        thicknessUpdates += 1
        withoutAnimations {
            for divider in boundaryLayers {
                divider.bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: thickness)
            }
            edgeLayer.bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: thickness * 2)
        }
    }

    @objc private func accessibilityMaterialsChanged() {
        let plain = accessibility.prefersPlainMaterials
        withoutAnimations {
            grainLayer.isHidden = plain
            leatherLayer.isHidden = plain
        }
    }

    private func applyMaterials(_ materials: NotebookMaterials) {
        withoutAnimations {
            grainLayer.backgroundColor = materials.paperFibrePattern
            leatherLayer.backgroundColor = materials.leatherPattern
        }
    }

    /// Shifts the leather so its pattern starts at the window origin. The layer spans whole
    /// tiles, so flipping it about its centre leaves that phase in place.
    private func updateLeatherPhase() {
        let side = NotebookMaterials.tileSide
        let phase = NotebookMaterials.patternPhase(at: convert(CGPoint.zero, to: nil))
        let size = CGSize(
            width: ((bounds.width + phase.x) / side).rounded(.up) * side,
            height: ((bounds.height + phase.y) / side).rounded(.up) * side
        )
        withoutAnimations {
            leatherLayer.bounds = CGRect(origin: .zero, size: size)
            leatherLayer.position = CGPoint(x: size.width / 2 - phase.x, y: size.height / 2 - phase.y)
        }
    }

    private func withoutAnimations(_ update: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }
}
