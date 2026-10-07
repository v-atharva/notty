import NottyCore
import UIKit

/// The colour screen's shade bar: a dark sheet along the bottom of the screen holding one strip
/// of the current hue from a pale tint to a deep shade. Each step is a large key; a ring marks
/// the step in use. New shades only recolour the steps, so the bar costs nothing per frame.
@MainActor
final class NotebookShadeBar: UIView {
    static let label = "Shades"

    let strip = UIView()
    let selectionRing = NotebookShadeSelectionRing()
    private(set) var steps: [NotebookShadeStep] = []
    /// The colour of each step, lightest first.
    private(set) var shades: [EditorHSBColor] = []
    private(set) var selectedIndex: Int?
    /// Told of a tapped step's index.
    var onSelect: (@MainActor (Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = NotebookTheme.colorPanelFill.uiColor
        layer.cornerRadius = NotebookTheme.shadeBarCornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.borderWidth = NotebookTheme.shellBorderWidth
        layer.shadowColor = NotebookTheme.shadowTone.uiColor.cgColor
        layer.shadowOpacity = Float(NotebookTheme.shellShadow.opacity)
        layer.shadowRadius = NotebookTheme.shellShadow.radius
        layer.shadowOffset = CGSize(width: 0, height: -NotebookTheme.shellShadow.offset.height)
        strip.layer.cornerRadius = NotebookTheme.shadeStripCornerRadius
        strip.layer.cornerCurve = .continuous
        strip.clipsToBounds = true
        // An outline keeps the strip's ends in sight where a step comes close to the sheet's charcoal.
        strip.layer.borderWidth = NotebookTheme.shellBorderWidth
        addSubview(strip)
        addSubview(selectionRing)
        selectionRing.isHidden = true
        accessibilityContainerType = .list
        accessibilityLabel = Self.label
        applyEdge()
        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (bar: NotebookShadeBar, _: UITraitCollection) in
            bar.applyEdge()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    /// How many steps the bar shows at `width`: fewer where narrow, so each stays a large key.
    static func stepCount(forWidth width: CGFloat) -> Int {
        width < NotebookTheme.compactShadeBarWidth ? NotebookTheme.compactShadeStepCount : NotebookTheme.shadeStepCount
    }

    /// Shows `shades`, marking the step at `selected`.
    func show(_ shades: [EditorHSBColor], selected: Int?) {
        if shades.count != steps.count { rebuildSteps(count: shades.count) }
        for (index, (step, shade)) in zip(steps, shades).enumerated() where shade != self.shades[safe: index] {
            step.shade = shade
        }
        self.shades = shades
        selectedIndex = selected
        for (index, step) in steps.enumerated() { step.isSelected = index == selected }
        placeSelectionRing()
    }

    /// The bar's height, including the band behind the home indicator.
    static func height(bottomInset: CGFloat) -> CGFloat {
        NotebookTheme.shadeBarHeight + bottomInset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = NotebookTheme.shadeBarInset
        strip.frame = CGRect(
            x: inset, y: inset, width: max(bounds.width - 2 * inset, 0), height: max(NotebookTheme.shadeBarHeight - 2 * inset, 0)
        )
        let width = strip.bounds.width / CGFloat(max(steps.count, 1))
        for (index, step) in steps.enumerated() {
            // Whole points between steps, so no hairline of the sheet shows through.
            let minX = (CGFloat(index) * width).rounded()
            let maxX = (CGFloat(index + 1) * width).rounded()
            step.frame = CGRect(x: minX, y: 0, width: maxX - minX, height: strip.bounds.height)
        }
        placeSelectionRing()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: NotebookTheme.shadeBarCornerRadius, height: NotebookTheme.shadeBarCornerRadius)
        ).cgPath
    }

    private func rebuildSteps(count: Int) {
        for step in steps { step.removeFromSuperview() }
        steps = (0..<count).map { index in
            let step = NotebookShadeStep(index: index, count: count)
            step.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            strip.addSubview(step)
            return step
        }
        shades = []
        accessibilityElements = steps
        setNeedsLayout()
    }

    private func placeSelectionRing() {
        guard let selectedIndex, steps.indices.contains(selectedIndex) else {
            selectionRing.isHidden = true
            return
        }
        let step = steps[selectedIndex]
        let inset = NotebookTheme.shadeSelectionInset
        selectionRing.frame = step.convert(step.bounds, to: self).insetBy(dx: inset, dy: inset)
        selectionRing.isHidden = false
    }

    private func applyEdge() {
        layer.borderColor = NotebookTheme.colorPanelEdge.cgColor(for: traitCollection)
        strip.layer.borderColor = NotebookTheme.colorFieldEdge.cgColor(for: traitCollection)
    }
}

/// One step of the shade bar: a key filled with its shade.
@MainActor
final class NotebookShadeStep: UIControl {
    let index: Int

    /// The shade the step selects, at the ink's alpha. The key shows it opaque: the alpha thins a
    /// stroke on ivory paper, and over the dark sheet it would only make the step look darker.
    var shade = EditorHSBColor(hue: 0, saturation: 0, brightness: 1) {
        didSet {
            backgroundColor = shade.with(alpha: 1).rgb.platformColor
            accessibilityValue = shade.rgb.hexString
        }
    }

    init(index: Int, count: Int) {
        self.index = index
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = Self.accessibilityLabel(index: index, count: count)
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(index:count:).")
    }

    override var isSelected: Bool {
        didSet { accessibilityTraits = isSelected ? [.button, .selected] : .button }
    }

    private static func accessibilityLabel(index: Int, count: Int) -> String {
        let position = "Shade \(index + 1) of \(count)"
        if index == 0 { return position + ", lightest" }
        if index == count - 1 { return position + ", darkest" }
        if index == count / 2 { return position + ", middle" }
        return position
    }
}

/// The ring on the selected shade, drawn as the handles are: white with a thin dark rim.
@MainActor
final class NotebookShadeSelectionRing: UIView {
    private let rim = CAShapeLayer()
    private let ring = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for (shape, width, tone) in [
            (rim, NotebookTheme.colorHandleRingWidth + 2 * NotebookTheme.colorHandleRimWidth, NotebookTheme.colorHandleRim),
            (ring, NotebookTheme.colorHandleRingWidth, NotebookTheme.colorHandleRing)
        ] {
            shape.fillColor = nil
            shape.lineWidth = width
            shape.strokeColor = tone.uiColor.cgColor
            layer.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: NotebookTheme.shadeSelectionCornerRadius).cgPath
        withoutAnimations {
            for shape in [rim, ring] {
                shape.frame = bounds
                shape.path = path
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
