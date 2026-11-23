// 好友和公開房間：好友代碼（就是對戰的 pid）、連結、QR code、Instagram 限動圖片。和 Android 版 app/lib/friends.dart 相同。
// 伺服器端在 supabase/battle_social.sql。連結格式：juango://friend/<好友代碼>、juango://room/<房間代碼>。

import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct BattleLink: Identifiable, Hashable {
    enum Kind: Hashable { case friend, room }
    let kind: Kind
    let code: String
    var id: String { "\(kind)-\(code)" }

    init?(url: URL) {
        guard url.scheme == "juango", let host = url.host() else { return nil }
        let raw = url.pathComponents.dropFirst().first ?? ""
        let c = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !c.isEmpty else { return nil }
        switch host {
        case "friend": kind = .friend
        case "room": kind = .room
        default: return nil
        }
        code = c
    }

    static func friendURL(_ c: String) -> String { "juango://friend/\(c.uppercased())" }
    static func roomURL(_ c: String) -> String { "juango://room/\(c.uppercased())" }

    /// a room to join, e.g. from a friend's invite
    init(room code: String) { kind = .room; self.code = code.uppercased() }
}

/// A friend invited me to their room (battle_my_invites)
struct BattleInvite: Decodable, Identifiable {
    var id: Int
    var name: String
    var code: String
}

struct Friend: Decodable, Identifiable, Hashable {
    var name: String, rating: Int, tier: Int
    var pid: String? = nil
    var tierName: String? = nil
    /// the room this friend has open and is waiting in
    var room: String? = nil
    var id: String { pid ?? name }
    var tierText: String { tierName ?? "等級 \(tier)" }
}

struct PublicRoom: Decodable, Identifiable, Hashable {
    var name: String, rating: Int, tier: Int, code: String
    var tierName: String? = nil
    var id: String { code }
    var tierText: String { tierName ?? "等級 \(tier)" }
}

@MainActor
enum Social {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func friends() async throws -> [Friend] {
        try decoder.decode([Friend].self, from: await Cloud.shared.rpc("battle_friend_list", [:], timeout: 10))
    }

    static func add(_ code: String) async throws -> Friend {
        try decoder.decode(Friend.self, from: await Cloud.shared.rpc("battle_add_friend", ["p_code": code], timeout: 10))
    }

    static func remove(_ pid: String) async throws {
        _ = try await Cloud.shared.rpc("battle_remove_friend", ["p_pid": pid], timeout: 10)
    }

    static func publicRooms() async throws -> [PublicRoom] {
        try decoder.decode([PublicRoom].self, from: await Cloud.shared.rpc("battle_public_rooms", [:], timeout: 10))
    }

    /// battle screens open right now: the app-wide check skips while one is up (the battle home checks on its own)
    static var battleOpen = 0

    /// The newest invite from a friend, taken off the server so it shows only once; nil if none.
    /// fromBattleHome: asked by an open battle screen sitting on its home page; otherwise nil while a battle screen is open
    static func nextInvite(fromBattleHome: Bool = false) async -> BattleInvite? {
        guard Cloud.shared.signedIn, fromBattleHome || battleOpen == 0,
              let data = try? await Cloud.shared.rpc("battle_my_invites", [:], timeout: 8),
              let first = (try? decoder.decode([BattleInvite].self, from: data))?.first else { return nil }
        _ = try? await Cloud.shared.rpc("battle_invite_dismiss", ["p_id": first.id], timeout: 8)
        return fromBattleHome || battleOpen == 0 ? first : nil
    }

    static func myPid() async throws -> String? {
        struct Me: Decodable { var pid: String? }
        return try decoder.decode(Me.self, from: await Cloud.shared.rpc("battle_me", ["p_level": NSNull()], timeout: 10)).pid
    }
}

// MARK: QR code

enum QR {
    static func image(_ s: String, scale: CGFloat = 12) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 160
    var body: some View {
        Group {
            if let ui = QR.image(text) {
                Image(uiImage: ui).interpolation(.none).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .padding(size > 300 ? 40 : 12)
        .background(.white, in: .rect(cornerRadius: size > 300 ? 56 : 16))
        .accessibilityLabel("QR code")
    }
}

/// 1080×1920（限動尺寸）的分享圖：標題、QR code、代碼
private struct ShareCard: View {
    let title, code, link, hint: String
    var body: some View {
        VStack(spacing: 44) {
            Text("捲字 JuanGo・單字對戰").font(.system(size: 52, weight: .semibold))
            Text(title).font(.system(size: 88, weight: .bold))
            QRCodeView(text: link, size: 620).padding(.vertical, 20)
            Text(code).font(.system(size: 120, weight: .bold, design: .monospaced)).kerning(12)
            Text(hint).font(.system(size: 42, weight: .medium)).multilineTextAlignment(.center).padding(.horizontal, 70)
        }
        .foregroundStyle(Color.onAccent)
        .frame(width: 1080, height: 1920)
        .background(Color.themeAccent)
        .environment(\.colorScheme, .light)
    }
}

@MainActor
func renderShareCard(title: String, code: String, link: String, hint: String) -> UIImage? {
    let r = ImageRenderer(content: ShareCard(title: title, code: code, link: link, hint: hint))
    r.scale = 1
    return r.uiImage
}

/// 從畫面最上層跳出系統分享選單（選單項目不能直接放 ShareLink）
@MainActor
func presentShareSheet(_ items: [Any]) {
    Task { @MainActor in
        // 等選單收起來再跳，不然會被擋下
        try? await Task.sleep(for: .milliseconds(350))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        }
        top.present(vc, animated: true)
    }
}

/// 直接打開 Instagram 限時動態編輯畫面（Meta「分享到限時動態」）：
/// 圖片放剪貼簿 com.instagram.sharedSticker.backgroundImage，再開 instagram-stories://share。
/// 2023 年起一定要帶 source_application＝Meta App ID，沒帶 Instagram 會說「不支援分享到限時動態」；
/// App ID 填在 Info.plist 的 FacebookAppID。
enum InstagramStory {
    enum Result { case opened, notInstalled, noAppID }

    static var appID: String {
        ((Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    static func share(_ image: UIImage) -> Result {
        guard let probe = URL(string: "instagram-stories://share"), UIApplication.shared.canOpenURL(probe) else { return .notInstalled }
        guard !appID.isEmpty, let png = image.pngData(),
              let url = URL(string: "instagram-stories://share?source_application=\(appID)") else { return .noAppID }
        UIPasteboard.general.setItems([["com.instagram.sharedSticker.backgroundImage": png]],
                                      options: [.expirationDate: Date().addingTimeInterval(300)])
        UIApplication.shared.open(url)
        return .opened
    }
}

// MARK: 好友頁

struct FriendsView: View {
    let model: BattleModel
    var myPid: String?
    /// opened from a friend link or QR code: add this code right away
    var addCode: String? = nil
    @State private var pid: String?
    @State private var friends: [Friend]?
    @State private var failed: String?
    @State private var code = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var card: UIImage?
    @State private var tapped: Friend?
    @State private var sharing = false
    private var cloud: Cloud { .shared }
    private var myCode: String? { (pid ?? myPid).map { $0.uppercased() } }
    private var cleanCode: String { code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    private static let hint = "用相機掃 QR code，或在捲字「單字對戰 › 好友」輸入代碼"

    var body: some View {
        // 卡片顏色要放在 List 裡面的內容上才有作用（和其他頁一樣），放在 List 外面會變成系統預設的灰色
        List { Group {
            if !cloud.signedIn {
                Section { Text("登入後就能加好友、邀請好友對戰。").foregroundStyle(.secondary) }
            } else {
                profile
                addFriend
                list
            }
        }.listRowBackground(Color.cardFill) }
        .themedBackground()
        .navigationTitle("好友")
        .task { await start() }
        .task {
            // 好友開房間時「加入房間」要及時出現
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if cloud.signedIn { await loadFriends() }
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        }
        .confirmationDialog(tapped?.name ?? "", isPresented: Binding(get: { tapped != nil }, set: { if !$0 { tapped = nil } }),
                            titleVisibility: .visible, presenting: tapped) { f in
            if let r = f.room { Button("加入房間") { model.join(r) } }
            Button("刪除好友", role: .destructive) { remove(f) }
        } message: { f in
            Text("\(f.tierText)・\(f.rating)")
        }
    }

    /// 個人資料卡：和單字對戰首頁的戰績相同，只是不能改名
    @ViewBuilder private var profile: some View {
        Section {
            if let p = model.me {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.name).font(.app(.headline))
                        Spacer()
                        Text(tierText(p.tierName, p.tier)).font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                    }
                    Text(verbatim: String(p.rating)).font(.app(size: 44, .bold)).monospacedDigit()
                    Text("\(p.wins) 勝　\(p.losses) 敗　\(p.draws) 和").font(.app(.subheadline)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } else if model.meFailed {
                Button("讀不到個人資料，再試一次") { Task { await model.load() } }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
            }
        }
    }

    /// 加好友：輸入朋友的代碼，或把自己的 QR code／代碼分享出去
    @ViewBuilder private var addFriend: some View {
        Section {
            HStack {
                TextField("輸入朋友的好友代碼", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .onSubmit { if cleanCode.count >= 6 { add(cleanCode) } }
                Button("加好友") { add(cleanCode) }.disabled(cleanCode.count < 6 || busy)
            }
            // 分隔線從列的最左邊畫起，不然只會畫在「加好友」按鈕和代碼文字下面
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if let c = myCode {
                VStack(spacing: 12) {
                    QRCodeView(text: BattleLink.friendURL(c), size: 150)
                    Text(c).font(.app(size: 26, .bold)).monospaced().kerning(3).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Button { sharing = true } label: {
                    Label("分享我的好友代碼", systemImage: "square.and.arrow.up")
                }
                .confirmationDialog("分享好友代碼", isPresented: $sharing, titleVisibility: .visible) {
                    Button("複製代碼") { UIPasteboard.general.string = c; notice = "已複製好友代碼" }
                    Button("分享連結") {
                        presentShareSheet(["加我捲字 JuanGo 好友，一起單字對戰！\n好友代碼：\(c)\n\(BattleLink.friendURL(c))"])
                    }
                    if let card {
                        Button("分享 QR code 圖片") {
                            presentShareSheet([card, "加我捲字 JuanGo 好友：\(c)\n\(BattleLink.friendURL(c))"])
                        }
                        Button("分享到 Instagram 限動") { story(card) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("加好友")
        } footer: {
            Text("朋友掃 QR code、點連結或輸入代碼，就會互相變成好友。")
        }
    }

    private func story(_ img: UIImage) {
        switch InstagramStory.share(img) {
        case .opened: break
        case .notInstalled: notice = "這台裝置沒有安裝 Instagram"
        // 還沒有 Meta App ID：Instagram 會拒絕直接開限動，先改用分享選單
        case .noAppID: presentShareSheet([img])
        }
    }

    @ViewBuilder private var list: some View {
        Section {
            if friends == nil && failed == nil { ProgressView().frame(maxWidth: .infinity) }
            ForEach(friends ?? []) { f in
                Button { tapped = f } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).foregroundStyle(.primary)
                            Text("\(f.tierText)・\(f.rating)").font(.app(.footnote)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if f.room != nil {
                            Text("加入房間").font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                        }
                    }
                }
            }
        } header: {
            Text(friends.map { "好友（\($0.count)）" } ?? "好友")
        } footer: {
            Text(failed ?? (friends?.isEmpty == true
                ? "還沒有好友。把好友代碼、連結或 QR code 傳給朋友吧。"
                : "好友開了房間會顯示「加入房間」。點好友可以加入或刪除。"))
        }
    }

    private func start() async {
        guard cloud.signedIn else { return }
        pid = myPid
        if pid == nil { pid = try? await Social.myPid() }
        if let c = myCode {
            card = renderShareCard(title: "加我好友", code: c, link: BattleLink.friendURL(c), hint: Self.hint)
        }
        await loadFriends()
        if let a = addCode, !a.isEmpty { add(a) }
    }

    private func loadFriends() async {
        do {
            friends = try await Social.friends()
            failed = nil
        } catch {
            failed = BattleModel.clean(error)
        }
    }

    private func add(_ c: String) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let f = try await Social.add(c)
                code = ""
                await loadFriends()
                notice = "已加 \(f.name) 為好友"
            } catch {
                // the server's own message may already say 無法加好友; don't show it twice
                let m = BattleModel.clean(error)
                notice = m.hasPrefix("無法加好友") ? m : "無法加好友：\(m)"
            }
        }
    }

    private func remove(_ f: Friend) {
        guard let p = f.pid else { return }
        Task {
            try? await Social.remove(p)
            await loadFriends()
        }
    }
}

// MARK: 公開房間

struct PublicRoomsView: View {
    let model: BattleModel
    @State private var rooms: [PublicRoom]?
    @State private var failed: String?

    var body: some View {
        List { Group {
            Section {
                if rooms == nil && failed == nil { ProgressView().frame(maxWidth: .infinity) }
                ForEach(rooms ?? []) { r in
                    Button { model.join(r.code, fromPublic: true) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).foregroundStyle(.primary)
                                Text("\(r.tierText)・\(r.rating)").font(.app(.footnote)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("加入").font(.app(.body, .semibold)).foregroundStyle(Color.themeAccent)
                        }
                    }
                }
            } footer: {
                Text(failed ?? (rooms?.isEmpty == true
                    ? "現在沒有公開房間。你也可以建立房間，再打開「公開房間」。"
                    : "房間對戰不影響積分。每 5 秒自動更新。"))
            }
        }.listRowBackground(Color.cardFill) }
        .themedBackground()
        .navigationTitle("公開房間")
        .task {
            while !Task.isCancelled {
                do {
                    rooms = try await Social.publicRooms()
                    failed = nil
                } catch {
                    failed = BattleModel.clean(error)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// 房間裡多出來的：公開／私人切換、加入電腦
struct BattleRoomOptions: View {
    let model: BattleModel
    var body: some View {
        VStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.roomPublic }, set: { model.setRoomPublic($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(model.roomPublic ? "公開房間" : "私人房間", systemImage: model.roomPublic ? "globe" : "lock.fill")
                        .font(.app(.headline)) // same size as the 加入電腦 button below
                    Text(model.roomPublic ? "所有人都能加入" : "知道代碼的人才能加入")
                        .font(.app(.footnote)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.cardFill, in: .rect(cornerRadius: 14))
            .disabled(model.roomID == nil)
            Button { model.addBot() } label: {
                Label(model.addingBot ? "電腦加入中…" : "加入電腦", systemImage: "desktopcomputer")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.addingBot || model.roomID == nil)
            Text("等不到朋友就讓電腦陪你打").font(.app(.footnote)).foregroundStyle(.secondary)
        }
    }
}
