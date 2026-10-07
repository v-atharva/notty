import UIKit

/// Paper behind the status bar, above the canvas and below every control, so ink scrolling
/// under the time and battery fades out while blank paper shows no band. It replaces the
/// system's scroll edge effect, follows the scroll directly and never animates.
@MainActor
final class NotebookStatusVeil: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    private let accessibility: NotebookMaterialAccessibility
    private var width: CGFloat = 0
    private var safeTop: CGFloat = 0
    private var isOverPaper = false
    /// True under Reduce Transparency, when the veil is an opaque band with no fade.
    private(set) var isOpaqueBand = false

    /// The backing layer, a gradient as `layerClass` declares.
    var gradientLayer: CAGradientLayer {
        layer as! CAGradientLayer
    }

    init(accessibility: NotebookMaterialAccessibility) {
        self.accessibility = accessibility
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        accessibility.notificationCenter.addObserver(
            self, selector: #selector(reduceTransparencyChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(accessibility:).")
    }

    /// - Parameters:
    ///   - safeTop: the top safe area: the status bar, plus any system bar laid over the canvas.
    ///   - isOverPaper: false while the page is zoomed below width fit, where the veil would
    ///     lie over the stone beside it.
    func update(width: CGFloat, safeTop: CGFloat, isOverPaper: Bool) {
        guard width != self.width || safeTop != self.safeTop || isOverPaper != self.isOverPaper else { return }
        self.width = width
        self.safeTop = safeTop
        self.isOverPaper = isOverPaper
        applyStyle()
    }

    @objc private func reduceTransparencyChanged() {
        applyStyle()
    }

    private func applyStyle() {
        let opaque = accessibility.isReduceTransparencyEnabled()
        let fade = opaque ? 0 : NotebookTheme.statusVeilFade
        let height = safeTop + fade
        let paper = NotebookPaperView.paperColor
        let veil = paper.withAlphaComponent(opaque ? 1 : NotebookTheme.statusVeilOpacity).cgColor
        withoutAnimations {
            isOpaqueBand = opaque
            // Transparent paper rather than clear, so the fade never passes through gray.
            gradientLayer.colors = [veil, veil, paper.withAlphaComponent(opaque ? 1 : 0).cgColor]
            gradientLayer.locations = [0, NSNumber(value: height > 0 ? safeTop / height : 1), 1]
            frame = CGRect(x: 0, y: 0, width: width, height: height)
            isHidden = !isOverPaper || safeTop <= 0 || width <= 0
        }
    }
}
