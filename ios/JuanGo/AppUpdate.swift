import SwiftUI

/// Self-update for the sideloaded build. `release/latest.json` on GitHub (rewritten by
/// tools/build_release.sh) names the newest build; a bigger `build` means an update. Installing
/// hands the IPA to SideInstaller (`sideinstaller://install`), falling back to its web page.
/// Installing the latest IPA again is also how the signature is refreshed before the 7-day
/// free-account profile runs out.
enum AppUpdate {
    static let manifest = URL(string: "https://raw.githubusercontent.com/HowWeiChi-app/JuanGo/main/release/latest.json")!

    struct Latest: Equatable {
        let version: String
        let build: Int
        let notes: String
        let ipa: URL
    }

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static func latest() async -> Latest? {
        var req = URLRequest(url: manifest, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = v["version"] as? String,
              let build = v["build"] as? Int,
              let s = v["ipa"] as? String, let ipa = URL(string: s), ipa.scheme == "https"
        else { return nil }
        return Latest(version: version, build: build, notes: v["notes"] as? String ?? "", ipa: ipa)
    }

    /// When the signing profile runs out (embedded.mobileprovision); nil for App Store / Xcode builds without one
    static let signatureExpiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static var daysLeft: Int? {
        signatureExpiry.map { Calendar.current.dateComponents([.day], from: .now, to: $0).day ?? 0 }
    }

    /// Hand the IPA to SideInstaller, else SideInstaller's web page (which shows where it downloads from)
    @MainActor static func install(_ ipa: URL) {
        let q = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let links = ["sideinstaller://install?url=\(q)", "https://sideinstaller.net/open.html?url=\(q)"]
            .compactMap(URL.init(string:))
        func open(_ i: Int) {
            guard i < links.count else { return }
            UIApplication.shared.open(links[i]) { ok in if !ok { open(i + 1) } }
        }
        open(0)
    }

    /// Re-install the newest build (refreshes the signature too); the direct release link when the manifest can't be read
    @MainActor static func installLatest() async {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let fallback = URL(string: "https://github.com/HowWeiChi-app/JuanGo/releases/download/v\(v)/JuanGo-\(v).ipa")!
        install(await latest()?.ipa ?? fallback)
    }
}

/// On launch: offer a newer build, or warn when the signature has two days or less left.
struct UpdateReminders: ViewModifier {
    @State private var update: AppUpdate.Latest?
    @State private var expiring = false
    /// once per launch
    @State private var checked = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !checked else { return }
                checked = true
                if let l = await AppUpdate.latest(), l.build > AppUpdate.currentBuild { update = l; return }
                if let d = AppUpdate.daysLeft, d <= 2 { expiring = true }
            }
            .alert("有新版本", isPresented: Binding(get: { update != nil }, set: { if !$0 { update = nil } }), presenting: update) { l in
                Button("更新") { AppUpdate.install(l.ipa) }
                Button("稍後", role: .cancel) {}
            } message: { l in
                Text("捲字 \(l.version)（\(l.build)）\n\n\(l.notes.isEmpty ? "" : l.notes + "\n\n")會交給 SideInstaller 安裝，學習紀錄都會留著。")
            }
            .alert("簽名快到期了", isPresented: $expiring) {
                Button("刷新簽名") { Task { await AppUpdate.installLatest() } }
                Button("稍後", role: .cancel) {}
            } message: {
                Text(expiryText + "。到期後 App 會打不開，刷新簽名就是重新安裝一次，學習紀錄都會留著。")
            }
    }

    private var expiryText: String {
        guard let d = AppUpdate.daysLeft else { return "" }
        return d <= 0 ? "簽名今天到期" : "簽名還剩 \(d) 天"
    }
}

/// Settings rows: signature expiry and the update / refresh button
struct UpdateSection: View {
    @State private var latest: AppUpdate.Latest?

    var body: some View {
        Section {
            if let e = AppUpdate.signatureExpiry {
                LabeledContent("簽名到期", value: "\(e.formatted(date: .abbreviated, time: .omitted))（還剩 \(max(AppUpdate.daysLeft ?? 0, 0)) 天）")
            }
            Button(hasUpdate ? "更新到 \(latest!.version)（\(latest!.build)）" : "刷新簽名") {
                Task { await AppUpdate.installLatest() }
            }
        } header: { Text("更新") } footer: {
            Text("會交給 SideInstaller 重新安裝最新版，順便刷新簽名，學習紀錄都會留著。")
        }
        .task { latest = await AppUpdate.latest() }
    }

    private var hasUpdate: Bool { (latest?.build ?? 0) > AppUpdate.currentBuild }
}
