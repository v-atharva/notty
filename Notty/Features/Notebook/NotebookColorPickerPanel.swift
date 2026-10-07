import NottyCore
import UIKit

// The colour screen's picker: a dark card with an eyedropper key, a saturation and brightness
// square, a hue slider, and fields for HEX, hue, saturation, brightness and alpha. Every control
// is UIKit, and a drag only moves a handle and recolours one layer, so nothing is redrawn as the
// user moves through colours.

/// How a colour reached the screen.
enum NotebookColorChange: Equatable {
    /// Mid-drag: the user is still moving through colours.
    case passing
    /// The user settled on it: a drag ended, a field was entered, a shade tapped or a sample taken.
    case settled
}

@MainActor
final class NotebookColorPickerPanel: UIView, UITextFieldDelegate {
    static let title = "Color Picker"
    static let hexLabel = "HEX"
    static let alphaLabel = "Alpha"
    static let fieldLabels: [EditorColorField: String] = [.hue: "H", .saturation: "S", .brightness: "B", .alpha: alphaLabel]

    let titleLabel = UILabel()
    let eyedropperKey = NotebookColorPanelKey(symbol: "eyedropper")
    let square = NotebookSaturationBrightnessSquare()
    let hueSlider = NotebookHueSlider()
    let hexField = NotebookColorTextField()
    /// Hue, saturation and brightness share one segmented well, as in the reference.
    let segmentWell = UIView()
    let fields: [EditorColorField: NotebookColorTextField]
    private let segmentDividers = [UIView(), UIView()]
    private let hexCaption = UILabel()
    private var captions: [EditorColorField: UILabel] = [:]

    /// The colour showing. Setting it moves the controls without reporting a change.
    var color: EditorHSBColor {
        didSet { refreshControls() }
    }
    /// Told of each colour the user reaches through the panel.
    var onChange: (@MainActor (EditorHSBColor, NotebookColorChange) -> Void)?
    var onEyedropper: (@MainActor () -> Void)?

    init(color: EditorHSBColor) {
        self.color = color
        var fields: [EditorColorField: NotebookColorTextField] = [:]
        for field in EditorColorField.allCases { fields[field] = NotebookColorTextField() }
        self.fields = fields
        super.init(frame: .zero)
        backgroundColor = NotebookTheme.colorPanelFill.uiColor
        layer.cornerRadius = NotebookTheme.panelCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = NotebookTheme.shellBorderWidth
        layer.shadowColor = NotebookTheme.shadowTone.uiColor.cgColor
        layer.shadowOpacity = Float(NotebookTheme.shellShadow.opacity)
        layer.shadowRadius = NotebookTheme.shellShadow.radius
        layer.shadowOffset = NotebookTheme.shellShadow.offset
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = Self.title

        titleLabel.text = Self.title
        titleLabel.textColor = NotebookTheme.colorPanelText.uiColor
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        eyedropperKey.accessibilityLabel = "Eyedropper"
        eyedropperKey.accessibilityHint = "Picks a color from your page."
        eyedropperKey.addAction(UIAction { [weak self] _ in self?.onEyedropper?() }, for: .touchUpInside)

        square.addAction(UIAction { [weak self] _ in self?.squareMoved() }, for: .valueChanged)
        square.addAction(UIAction { [weak self] _ in self?.dragEnded() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        hueSlider.addAction(UIAction { [weak self] _ in self?.hueMoved() }, for: .valueChanged)
        hueSlider.addAction(UIAction { [weak self] _ in self?.dragEnded() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])

        hexField.accessibilityLabel = "Hex color"
        hexField.autocapitalizationType = .allCharacters
        hexField.keyboardType = .asciiCapable
        hexField.delegate = self
        hexCaption.text = Self.hexLabel
        for field in EditorColorField.allCases {
            let textField = self.field(field)
            textField.keyboardType = .numberPad
            textField.accessibilityLabel = Self.accessibilityLabel(for: field)
            textField.delegate = self
            let caption = UILabel()
            caption.text = Self.fieldLabels[field]
            captions[field] = caption
        }

        segmentWell.backgroundColor = NotebookTheme.colorFieldFill.uiColor
        segmentWell.layer.cornerRadius = NotebookTheme.colorFieldCornerRadius
        segmentWell.layer.cornerCurve = .continuous
        segmentWell.layer.borderWidth = NotebookTheme.shellBorderWidth
        for field in [EditorColorField.hue, .saturation, .brightness] {
            self.field(field).isSegment = true
            segmentWell.addSubview(self.field(field))
        }
        for divider in segmentDividers { segmentWell.addSubview(divider) }

        for caption in [hexCaption] + EditorColorField.allCases.compactMap({ captions[$0] }) {
            caption.textColor = NotebookTheme.colorPanelLabel.uiColor
            caption.textAlignment = .center
            caption.adjustsFontForContentSizeCategory = true
            // Each field speaks its own name, so the caption under it would only repeat it.
            caption.isAccessibilityElement = false
            addSubview(caption)
        }
        for view: UIView in [titleLabel, eyedropperKey, square, hueSlider, hexField, segmentWell, field(.alpha)] {
            addSubview(view)
        }
        accessibilityElements = [titleLabel, eyedropperKey, square, hueSlider, hexField]
            + [EditorColorField.hue, .saturation, .brightness, .alpha].map { field($0) }
        addInteraction(UILargeContentViewerInteraction())

        applyTypefaces()
        applyTones()
        refreshControls()
        registerForTraitChanges(
            [UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self]
        ) { (panel: NotebookColorPickerPanel, _: UITraitCollection) in
            panel.applyTypefaces()
            panel.applyTones()
            panel.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(color:).")
    }

    func field(_ field: EditorColorField) -> NotebookColorTextField {
        fields[field]!
    }

    // MARK: Layout

    /// The panel's height at `width`, with the square at its preferred size.
    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = max(width - 2 * NotebookTheme.colorPanelPadding, 0)
        return fixedHeight + (inner * NotebookTheme.colorSquareAspectRatio).rounded()
    }

    /// The panel's height with the square at its minimum, the least it is given on a short window.
    var minimumHeight: CGFloat {
        fixedHeight + NotebookTheme.colorSquareMinimumHeight
    }

    /// Everything but the square, which gives way first on a short window.
    private var fixedHeight: CGFloat {
        let padding = NotebookTheme.colorPanelPadding
        return padding + NotebookTheme.colorKeySize + NotebookTheme.colorPanelSpacing
            + NotebookTheme.colorPanelSpacing / 2 + NotebookTheme.colorHueSliderHeight + NotebookTheme.colorPanelSpacing / 2
            + NotebookTheme.colorFieldHeight + NotebookTheme.colorFieldLabelGap + captionHeight + padding
    }

    private var captionHeight: CGFloat {
        hexCaption.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).height.rounded(.up)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = NotebookTheme.colorPanelPadding
        let inner = bounds.insetBy(dx: padding, dy: padding)
        let key = NotebookTheme.colorKeySize
        eyedropperKey.frame = CGRect(x: inner.minX, y: inner.minY, width: key, height: key)
        // The title stays centred on the panel and never reaches the key.
        let titleInset = key + NotebookTheme.colorFieldSpacing
        titleLabel.frame = CGRect(x: inner.minX + titleInset, y: inner.minY, width: max(inner.width - 2 * titleInset, 0), height: key)

        let squareTop = inner.minY + key + NotebookTheme.colorPanelSpacing
        let squareHeight = max(bounds.height - fixedHeight, 0)
        square.frame = CGRect(x: inner.minX, y: squareTop, width: inner.width, height: squareHeight)
        let sliderTop = square.frame.maxY + NotebookTheme.colorPanelSpacing / 2
        hueSlider.frame = CGRect(x: inner.minX, y: sliderTop, width: inner.width, height: NotebookTheme.colorHueSliderHeight)

        let fieldTop = hueSlider.frame.maxY + NotebookTheme.colorPanelSpacing / 2
        let height = NotebookTheme.colorFieldHeight
        let spacing = NotebookTheme.colorFieldSpacing
        let shared = max(inner.width - 2 * spacing, 0)
        let hexWidth = (shared * NotebookTheme.colorHexFieldShare).rounded()
        let alphaWidth = (shared * NotebookTheme.colorAlphaFieldShare).rounded()
        hexField.frame = CGRect(x: inner.minX, y: fieldTop, width: hexWidth, height: height)
        segmentWell.frame = CGRect(
            x: hexField.frame.maxX + spacing, y: fieldTop, width: shared - hexWidth - alphaWidth, height: height
        )
        field(.alpha).frame = CGRect(x: inner.maxX - alphaWidth, y: fieldTop, width: alphaWidth, height: height)
        let segment = segmentWell.bounds.width / 3
        for (index, field) in [EditorColorField.hue, .saturation, .brightness].enumerated() {
            self.field(field).frame = CGRect(x: CGFloat(index) * segment, y: 0, width: segment, height: height)
        }
        for (index, divider) in segmentDividers.enumerated() {
            divider.frame = CGRect(
                x: CGFloat(index + 1) * segment - NotebookTheme.dividerThickness / 2, y: 0,
                width: NotebookTheme.dividerThickness, height: height
            )
        }

        let captionTop = fieldTop + height + NotebookTheme.colorFieldLabelGap
        func placeCaption(_ caption: UILabel?, under frame: CGRect) {
            caption?.frame = CGRect(x: frame.minX, y: captionTop, width: frame.width, height: captionHeight)
        }
        placeCaption(hexCaption, under: hexField.frame)
        for field in [EditorColorField.hue, .saturation, .brightness] {
            placeCaption(captions[field], under: self.field(field).convert(self.field(field).bounds, to: self))
        }
        placeCaption(captions[.alpha], under: field(.alpha).frame)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: NotebookTheme.panelCornerRadius).cgPath
    }

    // MARK: Editing

    /// Ends typing in a field, keeping a valid entry. Returns whether a field was being typed in.
    @discardableResult
    func finishEditing() -> Bool {
        let wasEditing = isEditing
        endEditing(true)
        return wasEditing
    }

    var isEditing: Bool {
        ([hexField] + Array(fields.values)).contains(where: \.isFirstResponder)
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard let bounds = Range(range, in: current) else { return false }
        let proposed = current.replacingCharacters(in: bounds, with: string)
        return textField === hexField ? EditorInkColor.isHexTyping(proposed.uppercased()) : EditorColorField.allowsTyping(proposed)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        (textField as? NotebookColorTextField)?.isActive = true
        refreshFieldEdges()
    }

    /// An entry is applied when typing ends; one that changes nothing returns to the value shown.
    func textFieldDidEndEditing(_ textField: UITextField) {
        (textField as? NotebookColorTextField)?.isActive = false
        refreshFieldEdges()
        guard let next = change(enteredIn: textField) else {
            refreshControls()
            return
        }
        color = next
        onChange?(next, .settled)
    }

    /// The colour a field's entry asks for, or nil for an entry that is empty or incomplete or
    /// that only repeats what the field showed. The square and the slider reach finer values than
    /// the fields' whole numbers, so applying a value merely read would move the colour and start
    /// its trial again.
    private func change(enteredIn textField: UITextField) -> EditorHSBColor? {
        let entered = textField.text ?? ""
        if textField === hexField {
            guard let rgb = EditorInkColor(hex: entered, alpha: color.alpha), rgb.quantized != color.rgb.quantized else {
                return nil
            }
            return EditorHSBColor(rgb, keepingHue: color.hue, saturation: color.saturation)
        }
        guard let field = fields.first(where: { $0.value === textField })?.key, let value = field.value(from: entered),
              value != field.value(of: color) else { return nil }
        return field.applying(value, to: color)
    }

    // MARK: Private

    private func squareMoved() {
        color = color.with(saturation: square.saturation, brightness: square.brightness)
        onChange?(color, .passing)
    }

    private func hueMoved() {
        color = color.with(hue: hueSlider.hue)
        onChange?(color, .passing)
    }

    private func dragEnded() {
        onChange?(color, .settled)
    }

    private func refreshControls() {
        square.hue = color.hue
        square.saturation = color.saturation
        square.brightness = color.brightness
        hueSlider.hue = color.hue
        if !hexField.isFirstResponder { hexField.text = color.rgb.hexString }
        for (field, textField) in fields where !textField.isFirstResponder {
            textField.text = String(field.value(of: color))
            textField.accessibilityValue = Self.accessibilityValue(for: field, of: color)
        }
    }

    private func applyTypefaces() {
        titleLabel.font = NotebookTheme.cardTitle.scaledFont()
        let value = NotebookTheme.colorFieldValue.scaledFont()
        for textField in [hexField] + Array(fields.values) { textField.font = value }
        let caption = NotebookTheme.colorFieldLabel
        for label in [hexCaption] + Array(captions.values) {
            label.font = caption.scaledFont()
            if let text = label.text {
                label.attributedText = NSAttributedString(string: text, attributes: [.kern: caption.tracking])
            }
        }
    }

    private func applyTones() {
        let traits = traitCollection
        layer.borderColor = NotebookTheme.colorPanelEdge.cgColor(for: traits)
        segmentWell.layer.borderColor = NotebookTheme.colorFieldEdge.cgColor(for: traits)
        for divider in segmentDividers { divider.backgroundColor = NotebookTheme.colorFieldEdge.uiColor }
        refreshFieldEdges()
    }

    private func refreshFieldEdges() {
        let traits = traitCollection
        for textField in [hexField] + Array(fields.values) { textField.applyEdge(for: traits) }
    }

    private static func accessibilityLabel(for field: EditorColorField) -> String {
        switch field {
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .brightness: "Brightness"
        case .alpha: "Alpha"
        }
    }

    private static func accessibilityValue(for field: EditorColorField, of color: EditorHSBColor) -> String {
        let value = field.value(of: color)
        return field == .hue ? "\(value) degrees" : "\(value) percent"
    }
}

// MARK: - Square

/// Saturation across, brightness up, for one hue: a hue fill washed with white from the left and
/// darkened toward the bottom. A touch anywhere, by finger or Pencil, moves the ring there and
/// tracks it, and a change of hue recolours only the fill.
@MainActor
final class NotebookSaturationBrightnessSquare: UIControl {
    static let step = 0.05

    let hueFill = CALayer()
    let whiteWash = CAGradientLayer()
    let darkening = CAGradientLayer()
    let handle = NotebookColorHandle()
    private let field = CALayer()

    var hue: Double = 0 {
        didSet { if hue != oldValue { refreshFill() } }
    }
    var saturation: Double = 1 {
        didSet { if saturation != oldValue { placeHandle() } }
    }
    var brightness: Double = 1 {
        didSet { if brightness != oldValue { placeHandle() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.cornerRadius = NotebookTheme.colorSquareCornerRadius
        field.cornerCurve = .continuous
        field.masksToBounds = true
        whiteWash.colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        whiteWash.startPoint = CGPoint(x: 0, y: 0.5)
        whiteWash.endPoint = CGPoint(x: 1, y: 0.5)
        darkening.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.cgColor]
        for sublayer in [hueFill, whiteWash, darkening] { field.addSublayer(sublayer) }
        layer.addSublayer(field)
        // The ring sits beside the field, not in it, so it shows whole at the square's edges.
        addSubview(handle)
        isAccessibilityElement = true
        accessibilityLabel = "Saturation and brightness"
        accessibilityTraits = .adjustable
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "More saturated") { [weak self] _ in self?.adjust(saturation: Self.step) ?? false },
            UIAccessibilityCustomAction(name: "Less saturated") { [weak self] _ in self?.adjust(saturation: -Self.step) ?? false }
        ]
        refreshFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutAnimations {
            field.frame = bounds
            for sublayer in [hueFill, whiteWash, darkening] { sublayer.frame = bounds }
        }
        placeHandle()
    }

    /// The saturation and brightness under `point`, kept inside the square.
    func components(at point: CGPoint) -> (saturation: Double, brightness: Double) {
        guard bounds.width > 0, bounds.height > 0 else { return (saturation, brightness) }
        let x = min(max(point.x / bounds.width, 0), 1)
        let y = min(max(point.y / bounds.height, 0), 1)
        return (Double(x), Double(1 - y))
    }

    /// Where the ring shows for the colour.
    var handleCenter: CGPoint {
        CGPoint(x: bounds.width * saturation, y: bounds.height * (1 - brightness))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        track(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        track(touch)
        return true
    }

    override var accessibilityValue: String? {
        get {
            "Saturation \(Int((saturation * 100).rounded())) percent, brightness \(Int((brightness * 100).rounded())) percent"
        }
        set {}
    }

    override func accessibilityIncrement() {
        adjust(brightness: Self.step)
    }

    override func accessibilityDecrement() {
        adjust(brightness: -Self.step)
    }

    private func track(_ touch: UITouch) {
        let (saturation, brightness) = components(at: touch.location(in: self))
        guard saturation != self.saturation || brightness != self.brightness else { return }
        self.saturation = saturation
        self.brightness = brightness
        sendActions(for: .valueChanged)
    }

    @discardableResult
    private func adjust(saturation change: Double = 0, brightness brightnessChange: Double = 0) -> Bool {
        saturation = min(max(saturation + change, 0), 1)
        brightness = min(max(brightness + brightnessChange, 0), 1)
        sendActions(for: .valueChanged)
        sendActions(for: .touchUpInside)
        return true
    }

    private func refreshFill() {
        withoutAnimations {
            hueFill.backgroundColor = EditorHSBColor(hue: hue, saturation: 1, brightness: 1).rgb.platformColor.cgColor
        }
    }

    private func placeHandle() {
        handle.center = handleCenter
    }
}

// MARK: - Hue slider

/// The hue as a horizontal rainbow with a ring handle. Touches anywhere across the slider's full
/// key height, by finger or Pencil, move the ring.
@MainActor
final class NotebookHueSlider: UIControl {
    static let step = 5.0
    /// The hues the track's gradient passes through, the primaries and secondaries.
    static let trackHues = Array(stride(from: 0.0, through: 360, by: 60))

    let track = CAGradientLayer()
    let handle = NotebookColorHandle()

    var hue: Double = 0 {
        didSet { if hue != oldValue { placeHandle() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.colors = Self.trackHues.map {
            EditorHSBColor(hue: $0, saturation: 1, brightness: 1).rgb.platformColor.cgColor
        }
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        track.cornerRadius = NotebookTheme.colorHueTrackHeight / 2
        layer.addSublayer(track)
        addSubview(handle)
        isAccessibilityElement = true
        accessibilityLabel = "Hue"
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutAnimations {
            let height = NotebookTheme.colorHueTrackHeight
            track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            // Each hue lies under the ring where the ring picks it. The ring stops short of the
            // rounded ends, which the gradient fills with the red at both of its ends.
            if bounds.width > 0 {
                track.locations = Self.trackHues.map { NSNumber(value: Double(position(of: $0) / bounds.width)) }
            }
        }
        placeHandle()
    }

    /// The ring's centre runs between the rounded ends' centres.
    private var travel: (start: CGFloat, length: CGFloat) {
        let end = NotebookTheme.colorHueTrackHeight / 2
        return (end, max(bounds.width - 2 * end, 0))
    }

    /// Where along the slider the ring's centre shows `hue`.
    private func position(of hue: Double) -> CGFloat {
        let (start, length) = travel
        return start + length * hue / 360
    }

    func hue(at point: CGPoint) -> Double {
        let (start, length) = travel
        guard length > 0 else { return hue }
        return Double(min(max((point.x - start) / length, 0), 1)) * 360
    }

    var handleCenter: CGPoint {
        CGPoint(x: position(of: hue), y: bounds.midY)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        track(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        track(touch)
        return true
    }

    override var accessibilityValue: String? {
        get { "\(Int(hue.rounded())) degrees" }
        set {}
    }

    override func accessibilityIncrement() {
        adjust(by: Self.step)
    }

    override func accessibilityDecrement() {
        adjust(by: -Self.step)
    }

    private func track(_ touch: UITouch) {
        let hue = hue(at: touch.location(in: self))
        guard hue != self.hue else { return }
        self.hue = hue
        sendActions(for: .valueChanged)
    }

    private func adjust(by change: Double) {
        hue = min(max(hue + change, 0), 360)
        sendActions(for: .valueChanged)
        sendActions(for: .touchUpInside)
    }

    private func placeHandle() {
        handle.center = handleCenter
    }
}

// MARK: - Parts

/// A hollow white ring with a thin dark rim inside and out, so it reads on any colour.
@MainActor
final class NotebookColorHandle: UIView {
    private let rim = CAShapeLayer()
    private let ring = CAShapeLayer()

    override init(frame: CGRect) {
        let diameter = NotebookTheme.colorHandleDiameter
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isUserInteractionEnabled = false
        let inset = NotebookTheme.colorHandleRingWidth / 2 + NotebookTheme.colorHandleRimWidth
        let path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        for (shape, width, tone) in [
            (rim, NotebookTheme.colorHandleRingWidth + 2 * NotebookTheme.colorHandleRimWidth, NotebookTheme.colorHandleRim),
            (ring, NotebookTheme.colorHandleRingWidth, NotebookTheme.colorHandleRing)
        ] {
            shape.frame = bounds
            shape.path = path
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
}

/// A field on the dark panel: a recessed face with an outline that brightens while typing.
@MainActor
final class NotebookColorTextField: UITextField {
    /// A segment of the shared well draws no face or outline of its own until it is typed in.
    var isSegment = false {
        didSet { applyEdge(for: traitCollection) }
    }
    var isActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        textColor = NotebookTheme.colorPanelText.uiColor
        tintColor = NotebookTheme.colorPanelText.uiColor
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .done
        layer.cornerRadius = NotebookTheme.colorFieldCornerRadius
        layer.cornerCurve = .continuous
        applyEdge(for: traitCollection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:).")
    }

    func applyEdge(for traits: UITraitCollection) {
        backgroundColor = isSegment ? .clear : NotebookTheme.colorFieldFill.uiColor
        if isActive {
            layer.borderWidth = NotebookTheme.wellOutlineWidth
            layer.borderColor = NotebookTheme.colorFieldActiveEdge.cgColor(for: traits)
        } else {
            layer.borderWidth = isSegment ? 0 : NotebookTheme.shellBorderWidth
            layer.borderColor = NotebookTheme.colorFieldEdge.cgColor(for: traits)
        }
    }
}

/// A key on the dark cards, the eyedropper or Clear: a recessed face, an outline, and an ivory
/// glyph or word. Pressed, its outline brightens and it sinks by the rail's key travel.
@MainActor
final class NotebookColorPanelKey: UIControl {
    let glyph = UIImageView()
    let title = UILabel()

    init(symbol: String? = nil, title text: String? = nil) {
        super.init(frame: .zero)
        backgroundColor = NotebookTheme.colorFieldFill.uiColor
        layer.cornerRadius = NotebookTheme.colorKeyCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = NotebookTheme.shellBorderWidth
        if let symbol {
            glyph.image = UIImage(systemName: symbol)
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: NotebookTheme.colorKeyGlyphSize)
            glyph.contentMode = .center
            glyph.tintColor = NotebookTheme.colorPanelText.uiColor
            addSubview(glyph)
            largeContentImage = glyph.image
        }
        if let text {
            title.text = text
            title.textColor = NotebookTheme.colorPanelText.uiColor
            title.textAlignment = .center
            title.adjustsFontForContentSizeCategory = true
            title.font = NotebookTheme.keyLabel.scaledFont()
            addSubview(title)
            largeContentTitle = text
            accessibilityLabel = text
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        showsLargeContentViewer = true
        applyEdge()
        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (key: NotebookColorPanelKey, _: UITraitCollection) in
            key.applyEdge()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(symbol:title:).")
    }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { applyEdge() } }
    }

    override var isEnabled: Bool {
        didSet {
            applyEdge()
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = title.text == nil
            ? NotebookTheme.colorKeySize
            : title.intrinsicContentSize.width + 2 * NotebookTheme.actionKeyPadding
        return CGSize(width: max(width, NotebookTheme.colorKeySize), height: NotebookTheme.colorKeySize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let travel = isHighlighted ? NotebookTheme.pressTravel : 0
        glyph.frame = bounds.offsetBy(dx: 0, dy: travel)
        title.frame = bounds.offsetBy(dx: 0, dy: travel)
    }

    /// The outline and, while unavailable, the dimming, which stays lighter under Increase Contrast
    /// as it does on the rail.
    private func applyEdge() {
        let tone = isHighlighted ? NotebookTheme.colorFieldActiveEdge : NotebookTheme.colorFieldEdge
        layer.borderColor = tone.cgColor(for: traitCollection)
        let dimmed = traitCollection.accessibilityContrast == .high
            ? NotebookTheme.disabledOpacityIncreased : NotebookTheme.disabledOpacity
        alpha = isEnabled ? 1 : dimmed
        setNeedsLayout()
    }
}

extension NotebookTheme.Typeface {
    /// The face for UIKit text, scaled with Dynamic Type along the typeface's style. Labels that
    /// adjust for content size follow later changes by themselves.
    func scaledFont() -> UIFont {
        let base: UIFont = if let postScriptName, let named = UIFont(name: postScriptName, size: pointSize) {
            named
        } else if postScriptName != nil {
            .monospacedSystemFont(ofSize: pointSize, weight: weight.fontWeight)
        } else {
            .systemFont(ofSize: pointSize, weight: weight.fontWeight)
        }
        return UIFontMetrics(forTextStyle: style.textStyle).scaledFont(for: base)
    }
}
