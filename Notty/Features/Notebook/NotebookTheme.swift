import NottyCore
import SwiftUI
import UIKit

/// The single source of colours, metrics and typography for the notebook editor: ivory paper on
/// a warm stone backdrop, a matte ivory-gray shell for the header and cards, and a tool rail of
/// the system's regular glass over the page. The editor forces the light appearance, so a tone has
/// one value, plus an optional value for Increase Contrast.
enum NotebookTheme {
    /// A colour defined once and read from UIKit or SwiftUI. A tone with an Increase Contrast
    /// value resolves through the trait collection, so SwiftUI views follow the setting without
    /// branching; layers resolve it explicitly with `cgColor(for:)`.
    struct Tone: Sendable {
        let uiColor: UIColor

        var color: Color { Color(uiColor: uiColor) }
        /// Resolved against the current trait collection; layers use `cgColor(for:)` instead.
        var cgColor: CGColor { uiColor.cgColor }

        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
            uiColor = UIColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        /// A tone that takes `increased` while Increase Contrast is on.
        init(standard: Tone, increased: Tone) {
            let standard = standard.uiColor
            let increased = increased.uiColor
            uiColor = UIColor { traits in
                traits.accessibilityContrast == .high ? increased : standard
            }
        }

        /// The value for a layer drawn in a view with `traits`.
        func cgColor(for traits: UITraitCollection) -> CGColor {
            uiColor.resolvedColor(with: traits).cgColor
        }
    }

    /// A drop shadow. `radius` is the blur radius.
    struct Shadow: Sendable {
        let tone: Tone
        let radius: CGFloat
        let offset: CGSize
        let opacity: Double

        var color: Color { tone.color.opacity(opacity) }
    }

    /// A text role scaled with Dynamic Type.
    struct Typeface: Sendable {
        enum Weight: Sendable {
            case regular
            case medium
            case semibold

            var swiftUI: Font.Weight {
                switch self {
                case .regular: .regular
                case .medium: .medium
                case .semibold: .semibold
                }
            }

            var fontWeight: UIFont.Weight {
                switch self {
                case .regular: .regular
                case .medium: .medium
                case .semibold: .semibold
                }
            }
        }

        enum Style: Sendable {
            case title3
            case headline
            case body
            case callout
            case subheadline
            case footnote
            case caption
            case caption2

            var swiftUI: Font.TextStyle {
                switch self {
                case .title3: .title3
                case .headline: .headline
                case .body: .body
                case .callout: .callout
                case .subheadline: .subheadline
                case .footnote: .footnote
                case .caption: .caption
                case .caption2: .caption2
                }
            }

            var textStyle: UIFont.TextStyle {
                switch self {
                case .title3: .title3
                case .headline: .headline
                case .body: .body
                case .callout: .callout
                case .subheadline: .subheadline
                case .footnote: .footnote
                case .caption: .caption1
                case .caption2: .caption2
                }
            }
        }

        /// A bundled typewriter face such as Berkeley Mono; `nil` selects the system face.
        let postScriptName: String?
        /// Size at the default content size; Dynamic Type scales from here along `style`.
        let pointSize: CGFloat
        let style: Style
        /// Weight of the system face, and of the monospaced fallback when the named face is missing.
        let weight: Weight
        /// Letter spacing in points, for short capitalised readouts and the nameplate.
        var tracking: CGFloat = 0

        var font: Font {
            guard let postScriptName else {
                return .system(style.swiftUI, weight: weight.swiftUI)
            }
            // Font.custom silently falls back to the proportional system face, so check first
            // and keep the typewriter character with the system monospaced design instead.
            guard UIFont(name: postScriptName, size: pointSize) != nil else {
                return .system(style.swiftUI, design: .monospaced, weight: weight.swiftUI)
            }
            return .custom(postScriptName, size: pointSize, relativeTo: style.swiftUI)
        }
    }

    // MARK: - Paper and backdrop

    /// Writing paper, the head margin above page 1, and the colour the fibre texture averages to.
    static let paperIvory = Tone(red: 0.98, green: 0.96, blue: 0.91)
    /// Hairline where a page meets the backdrop; a solid charcoal line under Increase Contrast.
    static let paperEdge = Tone(
        standard: Tone(red: 0.47, green: 0.40, blue: 0.31, alpha: 0.65),
        increased: Tone(red: 0.17, green: 0.16, blue: 0.15)
    )
    /// Page divisions, including the top of page 1 below the head margin.
    static let paperDivider = Tone(
        standard: Tone(red: 0.47, green: 0.40, blue: 0.31, alpha: 0.30),
        increased: Tone(red: 0.47, green: 0.40, blue: 0.31, alpha: 0.55)
    )
    /// Flat stone beside the paper and above its head margin, without fibres, so nothing outside
    /// a page reads as writable.
    static let backdropStone = Tone(red: 0.812, green: 0.792, blue: 0.749)
    /// Near-black below the last page, where a pull or a fling past the end opens space for the
    /// end card. A page added there clears in from this dark, against which its frost stands out
    /// plainly, as it does not against light stone.
    static let backdropBelowPaper = Tone(red: 0.043, green: 0.043, blue: 0.043)
    /// How far the near-black reaches below the last page and to either side of it, in page
    /// points. At the smallest zoom a narrow window shows about 7,000 page points from top to
    /// bottom; this reaches past that even while a pinch bounces below the smallest zoom.
    static let belowPaperReach: CGFloat = 20_000
    /// Paper continues this far above page 1, so the space reserved for the chrome, the status
    /// bar and overscroll at the top all show paper rather than stone.
    static let headMarginLength: CGFloat = 600
    /// Gradient bands on the stone along the page sides, seen only when the page is narrower
    /// than the screen or pulled away from a side; they zoom with the page, so nothing blurs per
    /// frame. Below the page a shadow would lighten the near-black, so there is none.
    static let pageSideShadowDepth: CGFloat = 3
    static let pageSideShadowOpacity: CGFloat = 0.12
    /// Paper veil behind the status bar, so ink scrolling under the time and battery fades out.
    static let statusVeilOpacity: CGFloat = 0.94
    /// Length of the veil's fade below the top safe area.
    static let statusVeilFade: CGFloat = 10

    // MARK: - End of notebook

    /// The card a pull or a fling past the last page reveals on the near-black beneath it. Its two
    /// keys sit side by side at this width; a narrower window or a large text size stacks them.
    static let endCardWidth: CGFloat = 440
    /// Space between the last page and the card, and between the card and the bottom chrome.
    static let endCardGap: CGFloat = 20
    /// Space between the card's two keys, and between a key and the note beneath it.
    static let endCardKeySpacing: CGFloat = 12
    static let endCardNoteSpacing: CGFloat = 6

    // MARK: - Panels

    /// Top of the shell gradient shared by the header and cards.
    static let panelTop = Tone(red: 0.949, green: 0.937, blue: 0.918)
    /// Bottom of the shell gradient; the shell darkens slightly toward its lower edge.
    static let panelBottom = Tone(red: 0.886, green: 0.875, blue: 0.847)
    /// Flat shell for popovers and sheets, and for every shell under Increase Contrast.
    static let panelSurface = Tone(red: 0.918, green: 0.906, blue: 0.882)
    /// Bright line just inside a shell's top edge.
    static let panelHighlight = Tone(red: 1, green: 1, blue: 1, alpha: 0.85)
    /// Lower edge of a shell and outline of unselected chips; the full outline under Increase Contrast.
    static let panelLowerEdge = Tone(
        standard: Tone(red: 0.776, green: 0.765, blue: 0.729),
        increased: Tone(red: 0.333, green: 0.318, blue: 0.294)
    )
    /// Warm umber for every shadow, so shadows never turn the paper or the stone gray.
    static let shadowTone = Tone(red: 0.20, green: 0.165, blue: 0.125)
    /// The header's recessed display tray, light enough for 12 pt captions at 4.5:1.
    static let trayFill = Tone(red: 0.827, green: 0.812, blue: 0.776)
    /// Recess behind a selected control, as on the final rail.
    static let selectedWell = Tone(
        standard: Tone(red: 0.765, green: 0.749, blue: 0.706),
        increased: Tone(red: 0.678, green: 0.659, blue: 0.616)
    )
    /// Light caught by the lower lip of a recess, and the engraved nameplate.
    static let engraveHighlight = Tone(red: 1, green: 1, blue: 1, alpha: 0.60)
    /// One hairline between control groups and between the rail's two rows.
    static let divider = Tone(
        standard: Tone(red: 0.722, green: 0.702, blue: 0.659),
        increased: Tone(red: 0.427, green: 0.408, blue: 0.380)
    )

    // MARK: - Marks on panels

    /// Glyphs, titles, the selection mark and the focus ring.
    static let glyph = Tone(red: 0.17, green: 0.16, blue: 0.15)
    /// Quieter text and marks; dark enough for 4.5:1 inside a well or a pressed tray.
    static let glyphSecondary = Tone(
        standard: Tone(red: 0.314, green: 0.298, blue: 0.275),
        increased: Tone(red: 0.17, green: 0.16, blue: 0.15)
    )
    /// Placeholders and unavailable controls, held near 3:1 so they read as off yet stay visible.
    static let disabledGlyph = Tone(
        standard: Tone(red: 0.506, green: 0.490, blue: 0.459),
        increased: Tone(red: 0.408, green: 0.392, blue: 0.365)
    )
    /// Tint of text buttons in sheets and popovers: ink brown, never the accent.
    static let controlTint = Tone(
        standard: Tone(red: 0.36, green: 0.29, blue: 0.22),
        increased: Tone(red: 0.255, green: 0.20, blue: 0.145)
    )
    /// Near the save limit and incomplete history; system orange fails 3:1 on paper.
    static let cautionGlyph = Tone(
        standard: Tone(red: 0.478, green: 0.235, blue: 0.020),
        increased: Tone(red: 0.416, green: 0.204, blue: 0.016)
    )
    /// Save or recovery failed, and damaged history.
    static let alertGlyph = Tone(
        standard: Tone(red: 0.565, green: 0.149, blue: 0.114),
        increased: Tone(red: 0.490, green: 0.122, blue: 0.094)
    )

    // MARK: - Accent

    /// The one accent: the header's menu key, after the periwinkle key that ends the video's rail.
    static let accentFill = Tone(
        standard: Tone(red: 0.431, green: 0.439, blue: 0.784),
        increased: Tone(red: 0.384, green: 0.392, blue: 0.741)
    )
    /// Dark navy face on the accent key; white under Increase Contrast.
    static let accentGlyph = Tone(
        standard: Tone(red: 0.047, green: 0.051, blue: 0.176),
        increased: Tone(red: 1, green: 1, blue: 1)
    )
    /// Lower rim of the accent key, and its pressed overlay.
    static let accentRim = Tone(
        standard: Tone(red: 0.345, green: 0.353, blue: 0.659),
        increased: Tone(red: 0.333, green: 0.318, blue: 0.294)
    )
    static let accentKeySize = CGSize(width: 40, height: 36)
    static let accentKeyCornerRadius: CGFloat = 11
    static let accentPressedOverlayOpacity = 0.4

    // MARK: - Shell metrics

    /// Header, rail, status card and popover cards.
    static let panelCornerRadius: CGFloat = 20
    /// Collapsed floating handle and recovery cards.
    static let compactPanelCornerRadius: CGFloat = 16
    static let shellBorderWidth: CGFloat = 1
    /// Static drop shadow, baked once into a stretchable image so a moving shell never re-blurs.
    static let shellShadow = Shadow(tone: shadowTone, radius: 8, offset: CGSize(width: 0, height: 2), opacity: 0.16)
    /// How far the shadow image reaches past the shell on every side.
    static let shellShadowBleed: CGFloat = 12

    // MARK: - Glass

    /// The tool rail's Liquid Glass and that of its stand-ins: the system's regular glass, as its own
    /// toolbars use, unmodified. Its keys take the system's adaptive foreground on it, which stays
    /// legible over the ivory paper, the ink and the black below the last page alike; the system
    /// adapts it under Increase Contrast and Reduce Transparency.
    static let railGlass = Glass.regular
    /// The lens raised behind a selected key on the rail: the system's regular glass, unmodified.
    static let selectionGlass = Glass.regular

    // MARK: - Header

    static let headerHeight: CGFloat = 60
    /// Gap between the top safe area and the header.
    static let headerTopGap: CGFloat = 6
    /// Padding inside the header; the tray radius 20 - 8 = 12 keeps the corners concentric.
    static let headerPadding: CGFloat = 8
    /// Gap between the header and a docked toolbar, which stays put when the header leaves.
    static let headerToolbarGap: CGFloat = 8
    static let headerGlyphSize: CGFloat = 20
    static let nameplateLeadingInset: CGFloat = 16
    static let nameplateTrayGap: CGFloat = 14
    static let trayHeight: CGFloat = 44
    static let trayCornerRadius: CGFloat = 12
    /// Keeps the readouts beside the title on wide headers.
    static let trayMaxWidth: CGFloat = 480
    static let trayContentInset: CGFloat = 14
    static let trayShadowOpacity = 0.28
    static let trayShadowRadius: CGFloat = 2.5
    /// A pressed readout lights a cell this far inside the tray, so its corners stay concentric.
    static let readoutInset: CGFloat = 2
    /// The save readout never narrows below its glyph and the widest steady caption.
    static let statusReadoutMinWidth: CGFloat = 93
    static let readoutGlyphSize: CGFloat = 16
    /// A pressed readout sinks less than a pressed key, so its caption keeps 4.5:1.
    static let pressedTrayOpacity = 0.35
    /// The header fades over the last stretch of its scroll-away travel, never hanging under the status bar.
    static let headerFadeDistance: CGFloat = 24
    /// The header's inset from the window's sides, the same as a docked toolbar's margin.
    static let headerSideInset: CGFloat = 12
    /// Below this shell width the nameplate gives way to the title.
    static let headerNameplateMinimumWidth: CGFloat = 560
    /// Below this shell width the save readout drops its caption and a verified history its cell.
    static let headerCompactWidth: CGFloat = 480
    /// Least room between the tray and Undo; compact headers narrow it to the header padding.
    static let headerTrailingGap: CGFloat = 12
    /// The least room the title keeps beside the readouts; a header too narrow for it moves Redo
    /// into the notebook menu.
    static let headerTitleMinimumWidth: CGFloat = 96
    /// Space either side of a readout's glyph and caption.
    static let readoutPadding: CGFloat = 12
    /// Space between a readout's glyph and its caption.
    static let readoutSpacing: CGFloat = 6
    static let accentGlyphSize: CGFloat = 17
    /// The light caught along the accent key's top edge.
    static let accentHighlightOpacity = 0.35
    /// The focus ring drawn around the accent key.
    static let accentFocusCornerRadius: CGFloat = 14
    /// A header left part-way settles, a reveal springs in and a hide eases out. Under Reduce
    /// Motion, and when a pin brings it back, the header only fades.
    static let headerSettleDuration = 0.20
    static let headerRevealDuration = 0.28
    static let headerHideDuration = 0.18
    static let chromeFadeDuration = 0.15

    // MARK: - Notebook menu and recovery copies

    /// A menu row's trailing inset, and the gap between its glyph and its text.
    static let menuRowInset: CGFloat = 12
    /// Where a menu row's glyph column starts, well clear of the selected row's mark.
    static let menuGlyphInset: CGFloat = 16
    /// Every row glyph centres in a column as wide as the glyph, so titles line up across sections.
    static let menuGlyphColumnWidth: CGFloat = 20
    /// Focus's pencil and scribble runs wide; at this size it fills the glyph column as the other
    /// writing view glyphs do at the header glyph size, rather than spilling toward the mark.
    static let focusGlyphSize: CGFloat = 15
    /// Room above and below a writing view row's title and description.
    static let menuRowTextPadding: CGFloat = 4
    /// Least room between a writing view's text and its shortcut hint.
    static let menuShortcutGap: CGFloat = 8
    /// The longest writing view description shrinks, at most this far, rather than wrapping, to
    /// share its row with the shortcut hint at the standard text size.
    static let menuDescriptionMinimumScale: CGFloat = 0.85
    /// Space between a section's caps label and its rows.
    static let sectionLabelSpacing: CGFloat = 8
    /// Glyphs of the toolbar position segments and the planned-feature rows.
    static let menuSecondaryGlyphSize: CGFloat = 17
    /// The disabled rows of planned features under "Coming later".
    static let comingLaterRowHeight: CGFloat = 32
    /// Space between a recovery card's title and the line explaining it.
    static let recoveryCardTitleSpacing: CGFloat = 6

    // MARK: - Toolbar metrics

    /// Corner radius of the well behind a selected or pressed control.
    static let selectedWellCornerRadius: CGFloat = 12
    static let dividerThickness: CGFloat = 1
    /// Side of every tappable control; meets the 44 pt minimum touch target.
    static let controlSize: CGFloat = 44
    /// Point size of tool symbols; fixed so the rail height is stable, with the Large Content Viewer for accessibility sizes.
    static let glyphSize: CGFloat = 22
    static let swatchDiameter: CGFloat = 28
    /// One control plus the vertical strip insets.
    static let rowHeight: CGFloat = controlSize + stripInsets.top + stripInsets.bottom
    /// Gap between the two rows; the row hairline sits in it.
    static let rowSpacing: CGFloat = 4
    /// Keys sit almost edge to edge on one continuous shell.
    static let itemSpacing: CGFloat = 2
    static let dividerLength: CGFloat = 24
    /// Space either side of a divider; with the item spacing, groups sit 13 pt apart.
    static let dividerPadding: CGFloat = 4
    /// The hairline between the rail's rows stops this far short of the strip's ends.
    static let rowDividerInset: CGFloat = 12
    static let stripInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    /// The two ridges of the grip column.
    static let gripRidgeSize = CGSize(width: 2, height: 24)
    static let gripRidgeSpacing: CGFloat = 4
    /// Collapsed floating rail; it is the reveal control, so both sides are at least 44 pt.
    static let collapsedHandleSize = CGSize(width: 56, height: 44)
    /// The tool on the collapsed handle and a floating rail's collapse key.
    static let handleGlyphSize: CGFloat = 20
    /// Ink bead on the collapsed handle, showing the ink in use.
    static let handleBeadDiameter: CGFloat = 8
    /// Where the bead sits from the handle's centre, down and to the trailing side.
    static let handleBeadOffset: CGFloat = 10
    /// The faint tab left where Focus mode hid the tools, as it lies below the top dock; at a side
    /// dock it stands on end.
    static let revealTabSize = CGSize(width: 48, height: 20)
    static let revealTabHitSize = CGSize(width: 64, height: 44)
    /// A hiding rail fades and rises this far, quickly, and settles back without bounce.
    static let toolsHideTravel: CGFloat = 8
    static let toolsHideDuration = 0.18
    static let toolsRevealDuration = 0.24
    /// Fades that stand in for the tools' movement under Reduce Motion, and the reveal tab's fade in.
    static let toolsFadeDuration = 0.15
    /// The second row eases in and out on a spring of this length, slipping this far out from
    /// under the first as it opens.
    static let inkRowDuration = 0.3
    static let inkRowTravel: CGFloat = 8
    /// One frame at 60 Hz, the shortest change an animation can still delay.
    static let frameDuration = 1.0 / 60
    /// Dock markers fade in as a drag starts.
    static let dockMarkerFadeDuration = 0.12
    /// Opacity of the rail's content while writing is paused; the glass behind it stays as it is.
    static let disabledOpacity = 0.55
    /// The same, under Increase Contrast.
    static let disabledOpacityIncreased = 0.70
    /// A pressed control sinks into a lighter well than a selected one.
    static let pressedWellOpacity = 0.5
    /// Inner shadow that recesses the selected well below the shell.
    static let wellShadowOpacity = 0.30
    /// A selected control is already sunk, so a press deepens its shadow instead.
    static let wellPressedShadowOpacity = 0.45
    static let wellShadowRadius: CGFloat = 2
    static let wellShadowDepth: CGFloat = 1
    /// Under Increase Contrast a solid outline takes the place of a well's lit lower lip.
    static let wellOutlineWidth: CGFloat = 1.5
    /// How far a label drops while its key is held, like a key travelling.
    static let pressTravel: CGFloat = 1
    /// Seconds a released key takes to come back up; a press shows at once.
    static let keyReleaseDuration = 0.12
    /// The bar under a selected glyph or width dot, so selection never relies on colour alone.
    static let selectionMarkSize = CGSize(width: 14, height: 3)
    static let selectionMarkInset: CGFloat = 4
    /// As heavy as the selection mark, so focus reads at the same weight as selection.
    static let focusRingWidth: CGFloat = 3
    /// The visible preset capsule; the chip keeps the full control height for touch.
    static let presetChipHeight: CGFloat = 36
    static let presetChipPadding: CGFloat = 12
    static let presetDotDiameter: CGFloat = 12
    static let presetDotSpacing: CGFloat = 6
    /// The selection mark inside a selected chip sits this far above the capsule's bottom.
    static let presetMarkInset: CGFloat = 3
    /// Where a square preset key's ink bead sits from the key's centre: beside the family glyph's
    /// foot, clear of the selection mark.
    static let presetKeyBeadOffset = CGSize(width: 11, height: 6)
    static let swatchCheckmarkSize: CGFloat = 12
    /// Inner ring that keeps pale or mid-tone swatches defined on the shell and the well.
    static let swatchRingOpacity = 0.22
    /// Point size of the chevrons that page a scrolling strip.
    static let chevronSize: CGFloat = 13
    /// Seconds a chevron tap takes to page a strip.
    static let stripPageDuration = 0.25
    /// Seconds the strip edge takes to change between its resting hard edge and its moving fade.
    static let stripFadeDuration = 0.15
    /// Compact-width chip that shows the current ink and opens the ink panel.
    static let currentInkChipWidth: CGFloat = 56
    static let currentInkSwatchDiameter: CGFloat = 20
    static let inkPanelWidth: CGFloat = 320
    static let inkPanelPadding: CGFloat = 16
    static let inkPanelSectionSpacing: CGFloat = 12
    /// Wide enough for the longest preset name at the default text size.
    static let presetColumnMinimum: CGFloat = 150

    // MARK: - Dock targets

    /// Fill of a dock marker while a toolbar is dragged, of the marker it would land in, and of the landing slot.
    static let dockSlotFillOpacity = 0.35
    static let dockSlotTargetedFillOpacity = 0.7
    static let dockSlotLandingFillOpacity = 0.2
    /// Outlines are drawn in the glyph tone.
    static let dockSlotOutlineOpacity = 0.6
    static let dockSlotOutline = StrokeStyle(lineWidth: 1.5, dash: [6, 4])
    static let dockSlotLandingOutline = StrokeStyle(lineWidth: 2)
    /// Reduce Transparency forms of the three fills, composited over the paper in advance.
    static let dockSlotOpaqueFill = Tone(red: 0.905, green: 0.886, blue: 0.839)
    static let dockSlotTargetedOpaqueFill = Tone(red: 0.830, green: 0.812, blue: 0.767)
    static let dockSlotLandingOpaqueFill = Tone(red: 0.937, green: 0.918, blue: 0.869)

    // MARK: - Popovers, sheets and cards

    static let popoverWidth: CGFloat = 320
    /// The notebook menu widens to this at accessibility text sizes, where the window allows.
    static let accessibilityPopoverWidth: CGFloat = 480
    /// Least room a widened popover leaves beside it at each edge of the window.
    static let popoverWindowMargin: CGFloat = 20
    static let popoverPadding: CGFloat = 16
    /// Save, history and limit details read better with a little more room.
    static let detailPadding: CGFloat = 20
    static let writingViewRowHeight: CGFloat = 52
    static let menuRowHeight: CGFloat = 44
    /// Vertical mark at the leading edge of a selected menu row.
    static let rowMarkSize = CGSize(width: 3, height: 20)
    static let sectionSpacing: CGFloat = 12
    static let actionKeyHeight: CGFloat = 44
    static let actionKeyCornerRadius: CGFloat = 12
    /// Least space between an action key's label and its sides.
    static let actionKeyPadding: CGFloat = 16
    /// A held primary key lightens to this opacity; secondary keys sink into the pressed well.
    static let actionKeyPressedOpacity = 0.85
    static let statusCardWidth: CGFloat = 320
    static let statusCardMaxWidth: CGFloat = 480

    // MARK: - Colour picker screen

    /// Space between the screen's edges and its cards.
    static let colorScreenMargin: CGFloat = 24
    /// Space between the picker and the scratchpad.
    static let colorScreenCardGap: CGFloat = 32
    /// Space between the cards and the exit hint beneath them.
    static let colorScreenHintGap: CGFloat = 16
    /// The picker keeps this width where it fits, and narrows to the minimum before the
    /// scratchpad moves below it.
    static let colorPickerWidth: CGFloat = 400
    static let colorPickerMinimumWidth: CGFloat = 320
    /// The scratchpad beside the picker takes the rest of the width up to the maximum; below the
    /// minimum it moves under the picker instead.
    static let scratchpadMinimumWidth: CGFloat = 260
    static let scratchpadMaximumWidth: CGFloat = 520
    /// Under the picker, on a narrow window, the scratchpad is this tall where there is room.
    static let scratchpadStackedHeight: CGFloat = 280
    static let scratchpadMinimumHeight: CGFloat = 160
    /// The sheet of paper sits this far inside the scratchpad's frame, leaving a band for the
    /// border; the frame's radius 20 - 10 = 10 keeps the corners concentric.
    static let scratchpadPaperInset: CGFloat = 10
    static let scratchpadPaperCornerRadius: CGFloat = 10
    /// Space before the scratchpad's caption, past the paper's inset.
    static let scratchpadCaptionPadding: CGFloat = 12
    /// The scratchpad slides in from this far beyond its place as the picker glides aside.
    static let scratchpadEntryOffset: CGFloat = 32
    /// The picker's glide aside on the first colour chosen, and the cross-fade that replaces it
    /// under Reduce Motion.
    static let colorScreenGlideDuration = 0.45
    static let colorScreenFadeDuration = 0.25
    /// The screen's cards fade in as it opens and everything fades out as it closes.
    static let colorScreenEntranceDuration = 0.2
    static let colorScreenExitDuration = 0.2

    /// The picker panel, the scratchpad's frame and the shade bar: dark cards in the style of the
    /// reference, a warm charcoal that sits apart from the stone at 9.8:1.
    static let colorPanelFill = Tone(red: 0.137, green: 0.129, blue: 0.122)
    /// A faint rim on the cards; the cards' own contrast with the stone defines them, so it turns
    /// solid only under Increase Contrast.
    static let colorPanelEdge = Tone(
        standard: Tone(red: 1, green: 1, blue: 1, alpha: 0.10),
        increased: Tone(red: 0.706, green: 0.690, blue: 0.663)
    )
    /// The title and the values typed in the fields: 14.7:1 on the panel.
    static let colorPanelText = Tone(red: 0.980, green: 0.960, blue: 0.910)
    /// The gray labels under the fields: 6.3:1 on the panel.
    static let colorPanelLabel = Tone(
        standard: Tone(red: 0.651, green: 0.635, blue: 0.608),
        increased: Tone(red: 0.851, green: 0.835, blue: 0.808)
    )
    /// The fields' and keys' recessed face.
    static let colorFieldFill = Tone(red: 0.086, green: 0.082, blue: 0.078)
    /// The outline that marks a field or key as a control: 3.5:1 on the panel and 4.0:1 on the face.
    static let colorFieldEdge = Tone(
        standard: Tone(red: 0.478, green: 0.459, blue: 0.435),
        increased: Tone(red: 0.706, green: 0.690, blue: 0.663)
    )
    /// A field being typed in, and a key while pressed.
    static let colorFieldActiveEdge = colorPanelText
    /// The ring handles: white with a dark rim inside and out, so one of the two reaches 3:1 on
    /// any colour beneath.
    static let colorHandleRing = Tone(red: 1, green: 1, blue: 1)
    static let colorHandleRim = Tone(red: 0, green: 0, blue: 0, alpha: 0.6)

    static let colorPanelPadding: CGFloat = 20
    static let colorPanelSpacing: CGFloat = 18
    static let colorKeySize: CGFloat = 44
    static let colorKeyCornerRadius: CGFloat = 10
    static let colorKeyGlyphSize: CGFloat = 19
    static let colorSquareCornerRadius: CGFloat = 10
    /// The square's height for its width where the screen has room; it gives way first, down to
    /// its minimum, on a short window.
    static let colorSquareAspectRatio: CGFloat = 0.62
    static let colorSquareMinimumHeight: CGFloat = 120
    static let colorHandleDiameter: CGFloat = 26
    static let colorHandleRingWidth: CGFloat = 3
    static let colorHandleRimWidth: CGFloat = 1
    static let colorHueTrackHeight: CGFloat = 14
    /// The slider takes touches across a full key's height, well beyond its thin track.
    static let colorHueSliderHeight: CGFloat = 44
    static let colorFieldHeight: CGFloat = 44
    static let colorFieldCornerRadius: CGFloat = 8
    static let colorFieldSpacing: CGFloat = 12
    static let colorFieldLabelGap: CGFloat = 6
    /// The HEX field and the alpha field take these shares of the field row; the hue, saturation
    /// and brightness segments share the rest.
    static let colorHexFieldShare: CGFloat = 0.3
    static let colorAlphaFieldShare: CGFloat = 0.2

    /// The shade bar along the bottom of the screen, above the home indicator.
    static let shadeBarHeight: CGFloat = 136
    static let shadeBarInset: CGFloat = 16
    static let shadeBarCornerRadius: CGFloat = 20
    static let shadeStripCornerRadius: CGFloat = 12
    /// Eleven steps on a regular window, nine where it is narrow, so each stays a large target.
    static let shadeStepCount = 11
    static let compactShadeStepCount = 9
    static let compactShadeBarWidth: CGFloat = 600
    /// The ring on the selected step sits this far inside it.
    static let shadeSelectionInset: CGFloat = 8
    static let shadeSelectionCornerRadius: CGFloat = 8
    static let shadeBarEntranceDuration = 0.4

    /// The scratchpad's border: yellow while the colour is held, green once leaving would keep it.
    /// Both sit on the charcoal frame, at 9.4:1 and 7.2:1, and differ in lightness as well as hue;
    /// the status word beside the caption carries the state regardless.
    static let trialTryingBorder = Tone(red: 0.976, green: 0.741, blue: 0.153)
    static let trialReadyBorder = Tone(red: 0.298, green: 0.765, blue: 0.502)
    /// The status glyph and word on the frame: 10.3:1 and 8.9:1.
    static let trialTryingMark = Tone(red: 0.969, green: 0.788, blue: 0.322)
    static let trialReadyMark = Tone(red: 0.443, green: 0.835, blue: 0.592)
    static let trialBorderWidth: CGFloat = 3
    /// The border runs this far inside the frame's edge, in the band around the paper.
    static let trialBorderInset: CGFloat = 5
    /// The border's change from yellow to green.
    static let trialBorderTurnDuration = 0.25
    /// Space between the caption and its status, and between the status glyph and word.
    static let trialStatusSpacing: CGFloat = 10
    static let trialStatusGlyphSpacing: CGFloat = 4

    /// The "Color Selected" toast that rises from the border's starting point to rest above it.
    static let colorToastHeight: CGFloat = 36
    static let colorToastGap: CGFloat = 10
    static let colorToastPadding: CGFloat = 14
    static let colorToastSpacing: CGFloat = 6
    static let colorToastStartScale: CGFloat = 0.6
    static let colorToastEntranceDuration = 0.35
    static let colorToastExitDuration = 0.18
    /// The toast's checkmark on the shell: 5.2:1 at its darkest point.
    static let colorToastCheck = Tone(red: 0.106, green: 0.400, blue: 0.235)

    /// The eyedropper's loupe, which floats above the touch so the finger never hides it.
    static let eyedropperLoupeDiameter: CGFloat = 120
    static let eyedropperLoupeOffset: CGFloat = 96
    /// Each point of the notebook shows this many times larger in the loupe.
    static let eyedropperLoupeZoom: CGFloat = 6
    static let eyedropperLoupeRingWidth: CGFloat = 8
    static let eyedropperReticleSize: CGFloat = 10
    static let eyedropperHintInset: CGFloat = 24
    static let eyedropperHintPadding = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    static let colorFieldValue = Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 17, style: .body, weight: .medium)
    static let colorFieldLabel = Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 12, style: .caption, weight: .medium, tracking: 0.6)
    static let colorToastLabel = Typeface(postScriptName: "BerkeleyMono-SemiBold", pointSize: 14, style: .subheadline, weight: .semibold)

    // MARK: - Typography

    // Berkeley Mono, bundled in Medium and SemiBold through UIAppFonts, sets the nameplate, the
    // note title and short fixed-vocabulary readouts. It never reaches dense controls or handwriting.

    /// The "notty" nameplate at the leading end of the header.
    static let wordmark = Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 16, style: .callout, weight: .medium, tracking: 0.5)
    /// Note title in the header tray and sheet titles.
    static let noteTitle = Typeface(postScriptName: "BerkeleyMono-SemiBold", pointSize: 17, style: .headline, weight: .semibold)
    /// Save and history captions in the tray; the fixed width keeps READY, SAVED and SAVING from shifting.
    static let readoutCaption = Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 12, style: .caption, weight: .medium, tracking: 0.6)
    /// Caps section labels in popovers and the SOON label on the rail.
    static let sectionLabel = Typeface(postScriptName: "BerkeleyMono-Medium", pointSize: 11, style: .caption2, weight: .medium, tracking: 1.0)
    /// Titles of status and recovery cards.
    static let cardTitle = Typeface(postScriptName: "BerkeleyMono-SemiBold", pointSize: 20, style: .title3, weight: .semibold)
    /// Toolbar and menu labels; the system face keeps dense controls legible.
    static let controlLabel = Typeface(postScriptName: nil, pointSize: 13, style: .footnote, weight: .medium)
    /// Labels of action keys in popovers and cards.
    static let keyLabel = Typeface(postScriptName: nil, pointSize: 15, style: .subheadline, weight: .semibold)
    /// Font that sizes tool glyphs.
    static var glyphFont: Font { .system(size: glyphSize, weight: .regular) }
    /// Font that sizes header glyphs.
    static var headerGlyphFont: Font { .system(size: headerGlyphSize, weight: .regular) }
}

extension View {
    /// Sets the typeface's font together with its letter spacing.
    func notebookTypeface(_ typeface: NotebookTheme.Typeface) -> some View {
        font(typeface.font).tracking(typeface.tracking)
    }
}
