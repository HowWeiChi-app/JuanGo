import SwiftUI
import UIKit
import CoreText

/// The 字體 setting changes Chinese too, not only English: SF Rounded is paired with 圓體 (Yuanti TC) and New York
/// with 宋體 (Songti TC). Both are Apple system fonts that iOS downloads on demand, so nothing is bundled; until a
/// download finishes (or with no network) the Chinese falls back to 蘋方 and nothing breaks.
@MainActor @Observable
final class AppFont {
    static let shared = AppFont()

    struct Option {
        let name: String
        let design: UIFontDescriptor.SystemDesign
        let swiftDesign: Font.Design
        /// light / regular / bold PostScript names of the Chinese face, nil = 蘋方 (the system default)
        let cjk: [String]?
        let cjkName: String
    }
    static let options: [Option] = [
        .init(name: "系統", design: .default, swiftDesign: .default, cjk: nil, cjkName: "蘋方"),
        .init(name: "圓體", design: .rounded, swiftDesign: .rounded,
              cjk: ["STYuanti-TC-Light", "STYuanti-TC-Regular", "STYuanti-TC-Bold"], cjkName: "圓體"),
        .init(name: "襯線", design: .serif, swiftDesign: .serif,
              cjk: ["STSongti-TC-Light", "STSongti-TC-Regular", "STSongti-TC-Bold"], cjkName: "宋體"),
        // there is no monospaced Chinese face; CJK glyphs are already fixed-width, so 蘋方 stays
        .init(name: "等寬", design: .monospaced, swiftDesign: .monospaced, cjk: nil, cjkName: "蘋方"),
    ]

    /// bumped when a Chinese face finishes downloading, so every `Font.app` is rebuilt
    private(set) var version = 0
    private(set) var downloading: String?
    private(set) var failed: String?
    @ObservationIgnored private var cache: [String: Font] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var readyCache: [Int: Bool] = [:]

    /// whether the current option's Chinese faces are on the device (cached; checked again after a download)
    private var cjkReady: Bool {
        let i = AppSettings.shared.fontStyle
        if let r = readyCache[i] { return r }
        let r = option.cjk.map { $0.allSatisfy(Self.installed) } ?? false
        readyCache[i] = r
        return r
    }

    var option: Option { Self.options[min(Self.options.count - 1, max(0, AppSettings.shared.fontStyle))] }

    static func installed(_ name: String) -> Bool { UIFont(name: name, size: 12) != nil }

    /// A sample of option `i` (for the font choices themselves), with its Chinese face when it's on the device.
    static func preview(_ i: Int, size: CGFloat) -> Font {
        let o = options[i]
        if let names = o.cjk, installed(names[1]) { return .custom(names[1], fixedSize: size) }
        return .system(size: size, design: o.swiftDesign)
    }

    /// Downloads the current option's Chinese faces if iOS doesn't have them yet.
    func prepare() {
        guard let names = option.cjk, !names.allSatisfy(Self.installed) else { return }
        let key = names.joined()
        guard !requested.contains(key) else { return }
        requested.insert(key)
        downloading = option.cjkName
        failed = nil
        let label = option.cjkName
        let descriptors = names.map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) } as CFArray
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors, nil) { state, progress in
            switch state {
            case .didFinish:
                Task { @MainActor in
                    let s = AppFont.shared
                    s.downloading = nil
                    if !names.allSatisfy(Self.installed) { s.failed = label; s.requested.remove(key) }
                    s.cache = [:]; s.readyCache = [:]; s.version += 1
                    s.applyAppearance()
                }
            case .didFailWithError:
                Task { @MainActor in
                    let s = AppFont.shared
                    s.downloading = nil; s.failed = label; s.requested.remove(key)
                }
            default: break
            }
            return true
        }
    }

    /// Called when the 字體 setting changes.
    func styleChanged() {
        cache = [:]
        readyCache = [:]
        version += 1
        prepare()
        applyAppearance()
    }

    /// The UIKit-drawn parts (navigation titles, segmented controls, the search field, bar buttons) get the
    /// same font and theme colours as the SwiftUI text. Alerts, menus and the date picker can't be restyled.
    func applyAppearance() {
        let a = Attrs(self)
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [.font: a.large]
        nav.titleTextAttributes = [.font: a.inline]
        let seg = UISegmentedControl.appearance()
        seg.setTitleTextAttributes(a.segment(selected: false), for: .normal)
        seg.setTitleTextAttributes(a.segment(selected: true), for: .selected)
        seg.selectedSegmentTintColor = a.accent
        UISearchTextField.appearance().font = a.body
        for state: UIControl.State in [.normal, .highlighted, .disabled] {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: a.body], for: state)
        }
        Task { @MainActor in self.refreshLiveViews(a) }
    }

    /// Appearance proxies only reach controls made later; restyle the ones already on screen.
    @MainActor private func refreshLiveViews(_ a: Attrs) {
        func visit(_ v: UIView) {
            if let s = v as? UISegmentedControl {
                s.setTitleTextAttributes(a.segment(selected: false), for: .normal)
                s.setTitleTextAttributes(a.segment(selected: true), for: .selected)
                s.selectedSegmentTintColor = a.accent
            } else if let n = v as? UINavigationBar {
                n.largeTitleTextAttributes = [.font: a.large]
                n.titleTextAttributes = [.font: a.inline]
            } else if let t = v as? UISearchTextField {
                t.font = a.body
            }
            v.subviews.forEach(visit)
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes { scene.windows.forEach(visit) }
    }

    private struct Attrs {
        let large, inline, body, segmentFont, segmentBold: UIFont
        let accent: UIColor
        init(_ f: AppFont) {
            large = f.uiFont(style: .largeTitle, size: nil, weight: .bold)
            inline = f.uiFont(style: .headline, size: nil, weight: .semibold)
            body = f.uiFont(style: .body, size: nil, weight: .regular)
            segmentFont = f.uiFont(style: .subheadline, size: nil, weight: .medium)
            segmentBold = f.uiFont(style: .subheadline, size: nil, weight: .semibold)
            accent = UIColor(AppSettings.shared.theme.accent)
        }
        func segment(selected: Bool) -> [NSAttributedString.Key: Any] {
            selected ? [.font: segmentBold, .foregroundColor: UIColor.white] : [.font: segmentFont, .foregroundColor: UIColor.label]
        }
    }

    // MARK: building fonts

    func font(_ style: Font.TextStyle?, size: CGFloat?, weight: Font.Weight?) -> Font {
        _ = version   // observed: rebuild after a download or a setting change
        let opt = option
        let w = weight ?? (style == .headline ? .semibold : .regular)
        // 系統 / 等寬, or the Chinese face isn't on the device yet: plain SwiftUI fonts (keep live Dynamic Type)
        guard opt.cjk != nil, cjkReady else {
            if let style { return .system(style, design: opt.swiftDesign, weight: w) }
            return .system(size: size ?? 17, weight: w, design: opt.swiftDesign)
        }
        let key = "\(AppSettings.shared.fontStyle)|\(style.map { "\($0)" } ?? "-")|\(size ?? 0)|\(w)"
        if let f = cache[key] { return f }
        let f = Font(uiFont(style: style.map(Self.uiStyle), size: size, weight: Self.uiWeight(w)) as CTFont)
        cache[key] = f
        return f
    }

    func uiFont(style: UIFont.TextStyle?, size: CGFloat?, weight: UIFont.Weight) -> UIFont {
        let opt = option
        let pointSize = size ?? UIFont.preferredFont(forTextStyle: style ?? .body).pointSize
        var base = UIFont.systemFont(ofSize: pointSize, weight: weight)
        if let d = base.fontDescriptor.withDesign(opt.design) { base = UIFont(descriptor: d, size: pointSize) }
        guard let names = opt.cjk, cjkReady else { return base }
        let face = weight >= .semibold ? names[2] : weight <= .light ? names[0] : names[1]
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: [UIFontDescriptor(name: face, size: pointSize)]])
        return UIFont(descriptor: desc, size: pointSize)
    }

    private static func uiStyle(_ s: Font.TextStyle) -> UIFont.TextStyle {
        switch s {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }

    private static func uiWeight(_ w: Font.Weight) -> UIFont.Weight {
        switch w {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Font {
    /// The app's font for a text style: the 字體 setting's design for English plus the matching Chinese face.
    @MainActor static func app(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        AppFont.shared.font(style, size: nil, weight: weight)
    }
    @MainActor static func app(size: CGFloat, _ weight: Font.Weight? = nil) -> Font {
        AppFont.shared.font(nil, size: size, weight: weight ?? .regular)
    }
}

private struct KeepAppFont: ViewModifier {
    @Environment(AppSettings.self) private var settings
    func body(content: Content) -> some View { content.font(.app(.body)).fontDesign(settings.fontDesign) }
}

extension View {
    /// Put before `.searchable`: the content keeps the app font.
    func keepAppFont() -> some View { modifier(KeepAppFont()) }
    /// Put after `.searchable`. SwiftUI sizes the search drawer from the font it sees here: any custom font
    /// makes it 62pt tall instead of 44pt. So it sees the system body style, and the field's own text is
    /// switched to the app font in UIKit (`applyAppearance`), which doesn't change the height.
    func systemSearchField() -> some View { font(.body).fontDesign(.default).background(SearchFieldStyler()) }
}

/// Gives every search field on screen the app's body font, text and placeholder alike. SwiftUI sets both
/// itself when it builds or updates the field, so this runs again after that and whenever editing starts or ends.
private struct SearchFieldStyler: UIViewRepresentable {
    final class Probe: UIView {
        private var tokens: [NSObjectProtocol] = []
        override func didMoveToWindow() {
            super.didMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard window != nil else { return }
            for name in [UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restyleSoon() }
                })
            }
            restyleSoon()
        }
        func restyleSoon() {
            for delay in [0.0, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restyle() }
            }
        }
        private func restyle() {
            guard let window else { return }
            let font = AppFont.shared.uiFont(style: .body, size: nil, weight: .regular)
            func visit(_ v: UIView) {
                if let t = v as? UISearchTextField {
                    if t.font != font { t.font = font }
                    if let p = t.attributedPlaceholder, p.length > 0, (p.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) != font {
                        let m = NSMutableAttributedString(attributedString: p)
                        m.addAttribute(.font, value: font, range: NSRange(location: 0, length: m.length))
                        t.attributedPlaceholder = m
                    }
                    return
                }
                v.subviews.forEach(visit)
            }
            visit(window)
        }
    }
    func makeUIView(context: Context) -> Probe { let v = Probe(); v.isUserInteractionEnabled = false; return v }
    func updateUIView(_ v: Probe, context: Context) { v.restyleSoon() }
}
