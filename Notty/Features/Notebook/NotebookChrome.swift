import SwiftUI
import UIKit

// The editor's shared chrome. The header, the tool rail, handles, popovers and cards are all
// drawn from these pieces, so one material and one set of key states hold everywhere.

/// The matte ivory-gray shell under the header, the tool rail, handles and cards: a soft
/// vertical gradient, a bright line inside the top edge, a darker lower edge and a static
/// shadow baked once per corner radius. Under Increase Contrast it turns flat with a dark
/// outline all round. The shadow reaches `shellShadowBleed` past the shell, so hosting views
/// must not clip it.
struct NotebookPanelShell: View {
    var cornerRadius: CGFloat = NotebookTheme.panelCornerRadius
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shadow = NotebookMaterials.shellShadow(cornerRadius: cornerRadius)
        let caps = shadow.capInsets
        ZStack {
            Image(uiImage: shadow)
                .resizable(
                    capInsets: EdgeInsets(top: caps.top, leading: caps.left, bottom: caps.bottom, trailing: caps.right),
                    resizingMode: .stretch
                )
                .padding(-NotebookTheme.shellShadowBleed)
            if contrast == .increased {
                shape
                    .fill(NotebookTheme.panelSurface.color)
                    .overlay {
                        shape.strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                    }
            } else {
                shape
                    .fill(
                        LinearGradient(
                            colors: [NotebookTheme.panelTop.color, NotebookTheme.panelBottom.color],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay { shape.strokeBorder(Self.edge, lineWidth: NotebookTheme.shellBorderWidth) }
            }
        }
        .accessibilityHidden(true)
    }

    /// Lit along the top, shaded along the bottom and clear down the sides.
    private static var edge: LinearGradient {
        let highlight = NotebookTheme.panelHighlight.color
        let lowerEdge = NotebookTheme.panelLowerEdge.color
        return LinearGradient(
            stops: [
                .init(color: highlight, location: 0),
                .init(color: highlight.opacity(0), location: 0.3),
                .init(color: lowerEdge.opacity(0), location: 0.7),
                .init(color: lowerEdge, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// The recess behind a selected key: the well tone sunk by an inner shadow, with light caught
/// on its lower lip. A press deepens the shadow. Under Increase Contrast a dark outline takes
/// the place of the lip, and the well tone resolves darker by itself.
struct NotebookRecessedWell<WellShape: InsettableShape>: View {
    let shape: WellShape
    var pressed = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let depth = pressed ? NotebookTheme.wellPressedShadowOpacity : NotebookTheme.wellShadowOpacity
        shape
            .fill(
                NotebookTheme.selectedWell.color.shadow(
                    .inner(
                        color: NotebookTheme.shadowTone.color.opacity(depth),
                        radius: NotebookTheme.wellShadowRadius, x: 0, y: NotebookTheme.wellShadowDepth
                    )
                )
            )
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(NotebookTheme.glyph.color, lineWidth: NotebookTheme.wellOutlineWidth)
                } else {
                    shape.strokeBorder(NotebookRecessLip.gradient, lineWidth: NotebookTheme.shellBorderWidth)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The header's recessed display tray behind the note title and its readouts. Under Increase
/// Contrast it loses its inner shadow and gains an outline instead.
struct NotebookRecessedTray: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.trayCornerRadius, style: .continuous)
        if contrast == .increased {
            shape
                .fill(NotebookTheme.trayFill.color)
                .overlay {
                    shape.strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                }
                .accessibilityHidden(true)
        } else {
            shape
                .fill(
                    NotebookTheme.trayFill.color.shadow(
                        .inner(
                            color: NotebookTheme.shadowTone.color.opacity(NotebookTheme.trayShadowOpacity),
                            radius: NotebookTheme.trayShadowRadius, x: 0, y: NotebookTheme.wellShadowDepth
                        )
                    )
                )
                .overlay { shape.strokeBorder(NotebookRecessLip.gradient, lineWidth: NotebookTheme.shellBorderWidth) }
                .accessibilityHidden(true)
        }
    }
}

/// Light caught by the lower lip of a recess, fading out well above it.
private enum NotebookRecessLip {
    static var gradient: LinearGradient {
        let highlight = NotebookTheme.engraveHighlight.color
        return LinearGradient(
            stops: [.init(color: highlight.opacity(0), location: 0.6), .init(color: highlight, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// The single hairline between control groups, or between the rail's two rows.
struct NotebookChromeDivider: View {
    let axis: Axis

    var body: some View {
        Group {
            switch axis {
            case .vertical:
                Rectangle()
                    .frame(width: NotebookTheme.dividerThickness, height: NotebookTheme.dividerLength)
                    .padding(.horizontal, NotebookTheme.dividerPadding)
            case .horizontal:
                Rectangle()
                    .frame(height: NotebookTheme.dividerThickness)
                    .padding(.horizontal, NotebookTheme.rowDividerInset)
            }
        }
        .foregroundStyle(NotebookTheme.divider.color)
        .accessibilityHidden(true)
    }
}

// MARK: - Keys

/// Draws every key in the header and the rail the same way. Every state changes shape or
/// depth, never only colour: selection is the recessed well (the label adds a mark or
/// checkmark), a press sinks the key and drops its label a point, and keyboard focus draws a
/// ring. A disabled key shows none of them and dims its label.
struct NotebookKeyStyle: ButtonStyle {
    enum Outline {
        /// The rounded square behind glyphs, swatches and widths.
        case well
        /// The capsule behind a preset.
        case capsule
        /// A cell of the header's display tray.
        case readout
    }

    var isSelected = false
    var shape = Outline.well

    func makeBody(configuration: Configuration) -> some View {
        NotebookKey(label: configuration.label, isSelected: isSelected, isPressed: configuration.isPressed, shape: shape)
    }
}

extension NotebookKeyStyle {
    /// What a key draws behind itself in each interaction state.
    struct Background: View {
        let shape: Outline
        let isSelected: Bool
        let isPressed: Bool
        let isFocused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            switch shape {
            case .well:
                layers(RoundedRectangle(cornerRadius: NotebookTheme.selectedWellCornerRadius, style: .continuous))
            case .capsule:
                layers(Capsule())
            case .readout:
                layers(RoundedRectangle(
                    cornerRadius: NotebookTheme.trayCornerRadius - NotebookTheme.readoutInset, style: .continuous
                ))
            }
        }

        /// A pressed readout sinks less, so its caption keeps its contrast in the tray.
        private var pressedOpacity: Double {
            shape == .readout ? NotebookTheme.pressedTrayOpacity : NotebookTheme.pressedWellOpacity
        }

        private func layers<S: InsettableShape>(_ outline: S) -> some View {
            ZStack {
                // Faded rather than inserted, so a release eases out while a selection made by
                // the same tap appears at once over it.
                outline
                    .fill(NotebookTheme.selectedWell.color)
                    .animation(NotebookKeyRelease.animation(pressed: isPressed, reduceMotion: reduceMotion)) {
                        $0.opacity(isPressed && !isSelected ? pressedOpacity : 0)
                    }
                if isSelected {
                    NotebookRecessedWell(shape: outline, pressed: isPressed)
                }
                if isFocused {
                    outline.strokeBorder(NotebookTheme.glyph.color, lineWidth: NotebookTheme.focusRingWidth)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// The body of `NotebookKeyStyle`, given the button's press state.
struct NotebookKey<Label: View>: View {
    let label: Label
    let isSelected: Bool
    let isPressed: Bool
    let shape: NotebookKeyStyle.Outline
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.notebookKeysShowSelection) private var showsSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = isPressed && isEnabled
        label
            .modifier(NotebookKeyForeground())
            // Only the travel eases, so a mark the same tap selects appears at once.
            .animation(NotebookKeyRelease.animation(pressed: pressed, reduceMotion: reduceMotion)) {
                $0.offset(y: pressed ? NotebookTheme.pressTravel : 0)
            }
            .background {
                NotebookKeyStyle.Background(
                    shape: shape, isSelected: isSelected && showsSelection, isPressed: pressed,
                    isFocused: isFocused && isEnabled
                )
                // A preset's capsule is shorter than its touch area, and a readout's cell sits
                // inside the tray's corners.
                .frame(maxHeight: shape == .capsule ? NotebookTheme.presetChipHeight : .infinity)
                .padding(shape == .readout ? NotebookTheme.readoutInset : 0)
            }
    }
}

/// A key goes down at once and comes back up briefly eased. Only its travel and its press
/// shading animate; selection, shadows and sizes change at once.
enum NotebookKeyRelease {
    static func animation(pressed: Bool, reduceMotion: Bool) -> Animation? {
        pressed || reduceMotion ? nil : .easeOut(duration: NotebookTheme.keyReleaseDuration)
    }
}

/// Glyph and mark colour of a key, turning to the disabled tone when the key is unavailable. A key
/// that only a writing pause disables keeps the glyph tone, as its rail dims it with the rest of
/// its content; dimming the disabled tone as well would leave it unreadable. A key of a rail the
/// writing view is hiding keeps its tone too, as it fades out unchanged.
struct NotebookKeyForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.notebookKeysPaused) private var isPaused
    @Environment(\.notebookKeysHiding) private var isHiding

    func body(content: Content) -> some View {
        let live = isEnabled || isPaused || isHiding
        content.foregroundStyle((live ? NotebookTheme.glyph : NotebookTheme.disabledGlyph).color)
    }
}

extension EnvironmentValues {
    /// True inside a rail or handle that is disabled only while writing is paused.
    @Entry var notebookKeysPaused = false
    /// True inside a rail the writing view is hiding, whose keys are disabled from the moment the
    /// hide begins so they leave keyboard focus between strokes rather than as the fade ends.
    @Entry var notebookKeysHiding = false

    /// Whether a selected key draws its selection: while enabled, and in a rail that is disabled
    /// only because it is hiding, so the fade shows it as it was. A paused rail draws none.
    var notebookKeysShowSelection: Bool { isEnabled || (notebookKeysHiding && !notebookKeysPaused) }
}

/// The non-colour selection cue under a selected glyph or width dot.
struct NotebookSelectionMark: View {
    var body: some View {
        Capsule()
            .modifier(NotebookKeyForeground())
            .frame(width: NotebookTheme.selectionMarkSize.width, height: NotebookTheme.selectionMarkSize.height)
            .padding(.bottom, NotebookTheme.selectionMarkInset)
            .accessibilityHidden(true)
    }
}

/// The keys that carry the actions of a card, popover or sheet: one dark primary key and
/// lighter secondary keys on the shell material. Keys fill the width they are offered, so
/// stacked actions line up; place them in a bounded container.
struct NotebookActionKeyStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        NotebookActionKey(label: configuration.label, kind: kind, isPressed: configuration.isPressed)
    }
}

/// The body of `NotebookActionKeyStyle`, given the button's press state.
struct NotebookActionKey<Label: View>: View {
    let label: Label
    let kind: NotebookActionKeyStyle.Kind
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = isPressed && isEnabled
        let release = NotebookKeyRelease.animation(pressed: pressed, reduceMotion: reduceMotion)
        let shape = RoundedRectangle(cornerRadius: NotebookTheme.actionKeyCornerRadius, style: .continuous)
        label
            .notebookTypeface(NotebookTheme.keyLabel)
            .foregroundStyle((kind == .primary ? NotebookTheme.paperIvory : NotebookTheme.glyph).color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, NotebookTheme.actionKeyPadding)
            .frame(maxWidth: .infinity, minHeight: NotebookTheme.actionKeyHeight)
            .animation(release) { $0.offset(y: pressed ? NotebookTheme.pressTravel : 0) }
            .background { face(shape, pressed: pressed, release: release) }
            .overlay {
                if isFocused && isEnabled {
                    shape.strokeBorder(NotebookTheme.glyph.color, lineWidth: NotebookTheme.focusRingWidth)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : disabledOpacity)
    }

    private var disabledOpacity: Double {
        contrast == .increased ? NotebookTheme.disabledOpacityIncreased : NotebookTheme.disabledOpacity
    }

    @ViewBuilder
    private func face(_ shape: RoundedRectangle, pressed: Bool, release: Animation?) -> some View {
        switch kind {
        case .primary:
            shape
                .fill(NotebookTheme.glyph.color)
                .animation(release) { $0.opacity(pressed ? NotebookTheme.actionKeyPressedOpacity : 1) }
        case .secondary:
            ZStack {
                if contrast == .increased {
                    shape
                        .fill(NotebookTheme.panelSurface.color)
                        .overlay {
                            shape.strokeBorder(NotebookTheme.panelLowerEdge.color, lineWidth: NotebookTheme.shellBorderWidth)
                        }
                } else {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [NotebookTheme.panelTop.color, NotebookTheme.panelBottom.color],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .overlay { shape.strokeBorder(Self.lowerEdge, lineWidth: NotebookTheme.shellBorderWidth) }
                }
                shape
                    .fill(NotebookTheme.selectedWell.color)
                    .animation(release) { $0.opacity(pressed ? NotebookTheme.pressedWellOpacity : 0) }
            }
        }
    }

    private static var lowerEdge: LinearGradient {
        let edge = NotebookTheme.panelLowerEdge.color
        return LinearGradient(
            stops: [.init(color: edge.opacity(0), location: 0.7), .init(color: edge, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// A small capitalised heading over a group of rows in a popover or menu.
struct NotebookSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .notebookTypeface(NotebookTheme.sectionLabel)
            .textCase(.uppercase)
            .foregroundStyle(NotebookTheme.glyphSecondary.color)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status card

/// A card on the paper while a library or notebook opens, or when one cannot open or needs
/// recovery. The caller centres it. A message card stacks its actions as action keys: one
/// primary key, then any secondary keys.
struct NotebookStatusCard<Primary: View, Secondary: View>: View {
    private enum Content {
        case loading(caption: String)
        case message(title: String, text: String)
    }

    private let content: Content
    private let primary: Primary
    private let secondary: Secondary

    init(loading caption: String) where Primary == EmptyView, Secondary == EmptyView {
        content = .loading(caption: caption)
        primary = EmptyView()
        secondary = EmptyView()
    }

    /// - Parameters:
    ///   - primary: the one button that answers the message, drawn as the primary key.
    ///   - secondary: the other buttons, drawn as secondary keys in order below it.
    init(
        title: String, message: String,
        @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary
    ) {
        content = .message(title: title, text: message)
        self.primary = primary()
        self.secondary = secondary()
    }

    init(title: String, message: String, @ViewBuilder primary: () -> Primary) where Secondary == EmptyView {
        self.init(title: title, message: message, primary: primary) { EmptyView() }
    }

    var body: some View {
        switch content {
        case let .loading(caption):
            VStack(spacing: NotebookTheme.sectionSpacing) {
                ProgressView()
                    .tint(NotebookTheme.glyph.color)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(NotebookTheme.glyphSecondary.color)
                    .multilineTextAlignment(.center)
            }
            .padding(NotebookTheme.detailPadding)
            .frame(maxWidth: NotebookTheme.statusCardWidth)
            .background { NotebookPanelShell() }
            .accessibilityElement(children: .combine)
        case let .message(title, text):
            VStack(alignment: .leading, spacing: NotebookTheme.sectionSpacing) {
                Text(title)
                    .notebookTypeface(NotebookTheme.cardTitle)
                    .foregroundStyle(NotebookTheme.glyph.color)
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .font(.body)
                    .foregroundStyle(NotebookTheme.glyphSecondary.color)
                VStack(spacing: NotebookTheme.sectionSpacing) {
                    primary
                        .buttonStyle(NotebookActionKeyStyle(kind: .primary))
                    secondary
                        .buttonStyle(NotebookActionKeyStyle(kind: .secondary))
                }
                .padding(.top, NotebookTheme.sectionSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NotebookTheme.detailPadding)
            .frame(maxWidth: NotebookTheme.statusCardMaxWidth)
            .background { NotebookPanelShell() }
        }
    }
}

extension View {
    /// Centres a status card on the paper, scrolling it when a large text size makes it taller
    /// than the screen. The padding keeps the card's shadow clear of the edges.
    func centredOnPaper() -> some View {
        ViewThatFits(in: .vertical) {
            padding(NotebookTheme.detailPadding)
            ScrollView {
                padding(NotebookTheme.detailPadding)
            }
        }
    }
}
