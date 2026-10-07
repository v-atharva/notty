import NottyCore
import SwiftUI
import UIKit

/// The single source of colours, metrics and typography for the notebook editor: ivory paper on
/// a warm stone backdrop, with matte ivory-gray shells for the header and the tool rail. The
/// editor forces the light appearance, so a tone has one value, plus an optional value for
/// Increase Contrast.
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
    /// Flat stone wherever there is no paper, without fibres, so nothing outside a page reads
    /// as writable.
    static let backdropStone = Tone(red: 0.812, green: 0.792, blue: 0.749)
    /// Paper continues this far above page 1, so the space reserved for the chrome, the status
    /// bar and overscroll at the top all show paper rather than stone.
    static let headMarginLength: CGFloat = 600
    /// Gradient band below the last page; it zooms with the page, so nothing blurs per frame.
    static let pageShadowDepth: CGFloat = 6
    static let pageShadowOpacity: CGFloat = 0.18
    /// Narrower, lighter bands along the page sides, seen only when the page is narrower than
    /// the screen or pulled away from a side.
    static let pageSideShadowDepth: CGFloat = 3
    static let pageSideShadowOpacity: CGFloat = 0.12
    /// Paper veil behind the status bar, so ink scrolling under the time and battery fades out.
    static let statusVeilOpacity: CGFloat = 0.94
    /// Length of the veil's fade below the top safe area.
    static let statusVeilFade: CGFloat = 10
    /// The "Add page" tab on the backdrop below the last page.
    static let endTabHeight: CGFloat = 44
    static let endTabCornerRadius: CGFloat = 14
    static let endTabGap: CGFloat = 20
    /// Least scroll room below the last page: the tab plus its gaps, above the home indicator.
    static let endScrollMinimum: CGFloat = 104

    // MARK: - Panels

    /// Top of the shell gradient shared by the header, the rail, handles and cards.
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
    /// Contact shadow under small static pieces such as the reveal tab.
    static let contactShadow = Shadow(tone: shadowTone, radius: 1, offset: CGSize(width: 0, height: 1), opacity: 0.16)

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
    /// Hairline between the grip and the collapse key of a floating rail.
    static let gripSeparatorLength: CGFloat = 20
    /// Collapsed floating rail; it is the reveal control, so both sides are at least 44 pt.
    static let collapsedHandleSize = CGSize(width: 56, height: 44)
    /// The tool on the collapsed handle and the collapse key under a floating rail's grip.
    static let handleGlyphSize: CGFloat = 20
    /// Ink bead on the collapsed handle, showing the ink in use.
    static let handleBeadDiameter: CGFloat = 8
    /// Where the bead sits from the handle's centre, down and to the trailing side.
    static let handleBeadOffset: CGFloat = 10
    /// The faint tab left where Focus mode hid the tools.
    static let revealTabSize = CGSize(width: 48, height: 20)
    static let revealTabHitSize = CGSize(width: 64, height: 44)
    static let revealTabOpacity = 0.94
    /// A hiding rail fades and rises this far, quickly, and settles back without bounce.
    static let toolsHideTravel: CGFloat = 8
    static let toolsHideDuration = 0.18
    static let toolsRevealDuration = 0.24
    /// Fades that stand in for the tools' movement under Reduce Motion, and the reveal tab's fade in.
    static let toolsFadeDuration = 0.15
    /// Dock markers fade in as a drag starts.
    static let dockMarkerFadeDuration = 0.12
    /// Opacity of the rail's content while writing is paused; the shell stays opaque.
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
    /// Label of the end-of-paper tab, quieter than an action key because it sits on the backdrop.
    static let tabLabel = Typeface(postScriptName: nil, pointSize: 15, style: .subheadline, weight: .medium)
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
