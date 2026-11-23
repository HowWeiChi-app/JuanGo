import SwiftUI
import SwiftData

struct ProfileTab: View {
    @Query private var words: [Word]
    @Query(sort: \ReviewLog.date) private var logs: [ReviewLog]
    @State private var selectedDay: Date?
    @State private var showSettings = false
    @State private var dayLogs: DayLogs?
    struct DayLogs: Identifiable { let id = UUID(); let logs: [ReviewLog] }

    private var stats: Stats { Stats(logs: logs, words: words) }

    var body: some View {
        NavigationStack {
            List { Group {
                Section { streakCard }
                Section("統計") {
                    statRow("今天練習", stats.studiedToday, "checklist")
                    statRow("學過的字", stats.learnedTotal, "book.pages")
                    statRow("精通", stats.masteredTotal, "crown")
                    statRow("待複習", stats.dueCount, "arrow.triangle.2.circlepath")
                }
                Section { calendarCard }
                Section { badgesCard }
                Section { MasteryCard(distribution: stats.distribution, boxed: false) }
            }.listRowBackground(Color.cardFill) }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .themedBackground()
            .toolbar { ToolbarItem { Button("設定", pulso: "slider.horizontal.3") { showSettings = true } } }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $dayLogs) { HistoryView(logs: $0.logs) }
            #if DEBUG
            .task { if ProcessInfo.processInfo.environment["JUANGO_SETTINGS"] != nil { showSettings = true } }   // simulator testing
            #endif
        }
    }

    /// Streak up front, drawn in the flame colour.
    private var streakCard: some View {
        HStack(spacing: 16) {
            LIcon("flame.fill").font(.app(size: 40))
                .foregroundStyle(Color.themeAccent)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.themeAccent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(stats.streak)").font(.app(size: 40, .bold))
                    Text("天連續學習").font(.app(.headline))
                }
                Text(stats.studiedToday > 0 ? "今天已經練過了，明天見！" : "今天還沒練習，別讓火熄掉。")
                    .font(.app(.subheadline)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func statRow(_ title: String, _ n: Int, _ icon: String) -> some View {
        LabeledContent {
            Text("\(n)").font(.app(.body, .semibold)).monospacedDigit().contentTransition(.numericText())
        } label: {
            Label { Text(title) } icon: { LIcon(icon).foregroundStyle(.tint) }
        }
    }

    /// The last five weeks as a calendar grid; darker squares mean more words that day.
    private var calendarCard: some View {
        let cal = Calendar(identifier: .iso8601)
        let today = cal.startOfDay(for: .now)
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        let first = cal.date(byAdding: .day, value: -28, to: weekStart)!
        let days = (0..<35).map { cal.date(byAdding: .day, value: $0, to: first)! }
        let counts = days.map { stats.count(on: $0) }
        let top = max(1, counts.max() ?? 1)
        let chosen = selectedDay ?? today
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("學習日曆").font(.app(.headline, .bold))
                Spacer()
                Text("近 5 週・\(counts.filter { $0 > 0 }.count) 天有練習").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                        Text($0).font(.app(.caption2, .bold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<5, id: \.self) { week in
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { wd in
                            let k = week * 7 + wd, d = days[k], n = counts[k], future = d > today
                            Button { selectedDay = d } label: {
                                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                    .fill(future ? Color.clear : n == 0 ? Color.secondary.opacity(0.10) : Color.themeAccent.opacity(0.25 + 0.75 * Double(n) / Double(top)))
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                        .strokeBorder(cal.isDate(d, inSameDayAs: chosen) ? Color.primary : (future ? Color.secondary.opacity(0.25) : .clear), lineWidth: 1.5))
                                    .overlay {
                                        Text(d.formatted(.dateTime.day())).font(.app(size: 10, .semibold))
                                            .foregroundStyle(n > 0 && Double(n) / Double(top) > 0.4 ? Color.onAccent : Color.secondary)
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(future)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("\(d.formatted(.dateTime.month().day().locale(.zh)))，\(n == 0 ? "沒有練習" : "練了 \(n) 個字")")
                            .accessibilityAddTraits(cal.isDate(d, inSameDayAs: chosen) ? .isSelected : [])
                        }
                    }
                }
            }
            // the chosen day's words, newest first, in the same list as 主頁's 學習紀錄
            Button {
                dayLogs = DayLogs(logs: logs.filter { cal.isDate($0.date, inSameDayAs: chosen) }.reversed())
            } label: {
                HStack {
                    Text(chosen.formatted(.dateTime.month().day().weekday().locale(.zh))).foregroundStyle(.primary)
                    Spacer()
                    Text("練了 \(stats.count(on: chosen)) 個字").fontWeight(.bold).foregroundStyle(.primary)
                    if stats.count(on: chosen) > 0 { LIcon("chevron.right").font(.app(.footnote, .semibold)).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(stats.count(on: chosen) == 0)
            .font(.app(.subheadline))
        }
        .padding(.vertical, 6)
    }

    private var badgesCard: some View {
        let earned = BadgeKind.all.map { $0.earned(for: BadgeKind.value($0.id, stats: stats)) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("成就").font(.app(.headline, .bold))
                Spacer()
                Text("已解鎖 \(earned) 枚").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                ForEach(BadgeKind.all) { k in
                    BadgeMedal(kind: k, value: BadgeKind.value(k.id, stats: stats), size: 56).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var confirmWipe = false
    @State private var pickBackup = false
    @State private var pendingBackup: BackupFile?
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form { Group {
                Section {
                    NavigationLink { ProSettingsView() } label: {
                        row("sparkles", "捲字 Pro", ProStore.shared.plan.map { $0.name + (ProStore.shared.devUnlocked ? "・開發版" : "") } ?? "免費版")
                    }
                }
                Section("學習") {
                    NavigationLink {
                        Form { Group {
                            Section {
                                Toggle("考前倒數", isOn: $settings.examOn)
                                if settings.examOn {
                                    Picker("考試", selection: $settings.examName) {
                                        ForEach(ExamPlan.names, id: \.self) { Text($0).tag($0) }
                                    }
                                    DatePicker("考試日期", selection: $settings.examDate,
                                               in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                                    Picker("要學完", selection: $settings.examTop) {
                                        Text("大考第 1–2 級").tag(2)
                                        Text("大考第 1–4 級").tag(4)
                                        Text("大考第 1–6 級").tag(6)
                                    }
                                }
                            } header: {
                                Text("考前倒數")
                            } footer: {
                                Text("依考試日期和還沒學過的字，自動算出每天要學幾個新字；字不夠時會從大考詞彙補進「我的單字」。考前兩週只複習。")
                            }
                            Section("每日新字") {
                                Stepper("\(settings.dailyGoal) 個 / 天", value: $settings.dailyGoal, in: 1...100)
                                    .disabled(settings.examOn)
                            }
                            Section("單字程度") {
                                Picker("程度", selection: $settings.level) {
                                    ForEach(examLevels, id: \.self) { Text("\(levelLabel($0))・\(LevelTest.blurb($0))").tag($0) }
                                }.pickerStyle(.inline).labelsHidden()
                            }
                        }.listRowBackground(Color.cardFill) }.themedBackground().navigationTitle("每日計畫")
                    } label: { row("smallcircle.filled.circle", "每日計畫", "每日新字與單字程度") }
                    NavigationLink {
                        Form { Group {
                            Toggle("顯示例句翻譯", isOn: $settings.showTranslation)
                            Toggle("自動唸單字", isOn: $settings.autoSpeak)
                            Toggle("震動回饋", isOn: $settings.haptics)
                            VStack(alignment: .leading) {
                                Text("發音速度")
                                Slider(value: $settings.speechRate, in: 0.3...0.6) { Text("速度") } minimumValueLabel: { LIcon("tortoise") } maximumValueLabel: { LIcon("hare") }
                            }
                            Button("試聽") { Speech.say("resilient") }
                            Button("重新顯示學習規則與探索教學") { settings.studyRulesSeen = false; settings.exploreTipsDone = false }
                        }.listRowBackground(Color.cardFill) }.themedBackground().navigationTitle("答題與發音")
                    } label: { row("graduationcap.fill", "答題與發音", "例句翻譯、發音與震動") }
                    NavigationLink {
                        Form { Group {
                            Toggle("每日提醒", isOn: $settings.reminderOn)
                            if settings.reminderOn {
                                DatePicker("提醒時間", selection: $settings.reminderDate, displayedComponents: .hourAndMinute)
                            }
                        }.listRowBackground(Color.cardFill) }.themedBackground().navigationTitle("每日提醒")
                    } label: { row("bell.fill", "每日提醒", settings.reminderOn ? "每天 \(settings.reminderText)" : "關閉") }
                }
                Section("單字") {
                    NavigationLink {
                        Form { Group {
                            Toggle("清單顯示中文意思", isOn: $settings.listShowMeaning)
                            Toggle("單字卡顯示音標", isOn: $settings.exploreShowIPA)
                            Toggle("查看單字時自動發音", isOn: $settings.detailAutoSpeak)
                        }.listRowBackground(Color.cardFill) }.themedBackground().navigationTitle("單字顯示")
                    } label: { row("text.book.closed.fill", "單字顯示", "中文意思、音標與自動發音") }
                    NavigationLink { AITranslationSettings() } label: {
                        row("sparkles", "AI 翻譯", WordTranslator.shared.providerName)
                    }
                }
                Section {
                    Picker("外觀", selection: $settings.appearance) { Text("跟隨系統").tag(0); Text("淺色").tag(1); Text("深色").tag(2) }
                    Picker("字體", selection: $settings.fontStyle) {
                        ForEach(Array(AppFont.options.enumerated()), id: \.offset) { i, o in
                            Text(o.name).tag(i)
                        }
                    }
                    ThemeGrid(selection: $settings.themeID).padding(.vertical, 6)
                } header: { Text("外觀") } footer: {
                    if let d = AppFont.shared.downloading {
                        Text("正在下載\(d)…")
                    } else if let f = AppFont.shared.failed {
                        Text("\(f)下載失敗，連上網路後再選一次。")
                    } else {
                        Text("選單和提示視窗是系統字體。")
                    }
                }
                Section("帳號") {
                    NavigationLink { AccountView() } label: {
                        row("person.crop.circle.fill", "帳號登入",
                            Cloud.shared.session.map { "已登入 \($0.email)" } ?? "登入後可雲端備份和單字對戰")
                    }
                }
                if Cloud.shared.signedIn {
                    Section("單字對戰") {
                        NavigationLink { BattleSettingsView() } label: {
                            row("hand.raised.fill", "排行榜與封鎖", "不顯示在排行榜、已封鎖的玩家")
                        }
                    }
                }
                Section {
                    Button("匯出備份") {
                        do { presentShareSheet(try Backup.write(Backup.full(ctx))) }
                        catch { message = "匯出失敗：\(error.localizedDescription)" }
                    }
                    Button("從備份還原") { pickBackup = true }
                } header: { Text("備份") } footer: {
                    Text("匯出的檔案包含單字、進度、清單和設定（不含 API key）。")
                }
                Section("資料") {
                    Button("重設所有學習進度") { confirmReset = true }
                    Button("清除所有單字與紀錄", role: .destructive) { confirmWipe = true }
                    Button("重新進行新手導覽") { settings.onboarded = false; dismiss() }
                }
                UpdateSection()
                Section {
                    LabeledContent("字典", value: "\(Dictionary_.all.count) 個內建單字")
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    NavigationLink("關於與授權") { AboutView() }
                } footer: {
                    Text("大考詞彙和學測考古題永遠免費。資料來源、授權和隱私說明請見「關於與授權」。")
                }
            }.listRowBackground(Color.cardFill) }.themedBackground()
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) { dismiss() } } }
            .fileImporter(isPresented: $pickBackup, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do { pendingBackup = try Backup.read(url) } catch { message = error.localizedDescription }
                case .failure(let e): message = e.localizedDescription
                }
            }
            .backupImport($pendingBackup, ctx: ctx) { message = "還原完成：\($0)" }
            #if DEBUG
            .task {   // simulator testing: SIMCTL_CHILD_JUANGO_EXPORT=1 opens the share sheet for a backup
                if ProcessInfo.processInfo.environment["JUANGO_EXPORT"] != nil, let url = try? Backup.write(Backup.full(ctx)) {
                    try? await Task.sleep(for: .seconds(1)); presentShareSheet(url)
                }
            }
            #endif
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            }
            .alert("重設所有學習進度？", isPresented: $confirmReset) {
                Button("重設", role: .destructive) { resetProgress() }
                Button("取消", role: .cancel) {}
            } message: { Text("單字會保留，但熟練度和學習紀錄會歸零。") }
            .alert("清除所有單字與紀錄？", isPresented: $confirmWipe) {
                Button("全部清除", role: .destructive) { wipe() }
                Button("取消", role: .cancel) {}
            } message: { Text("這個動作無法復原。") }
        }
    }

    private func row(_ icon: String, _ title: String, _ sub: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.app(.headline)); Text(sub).font(.app(.footnote, .semibold)).foregroundStyle(.secondary) }
        } icon: {
            LIcon(icon).font(.app(.subheadline, .semibold)).foregroundStyle(Color.onAccent)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.themeAccent))
        }
        .padding(.vertical, 4)
    }

    private func resetProgress() {
        for w in (try? ctx.fetch(FetchDescriptor<Word>())) ?? [] { w.srsLevel = 0; w.dueDate = nil; w.lastReviewed = nil; w.reviewCount = 0 }
        try? ctx.delete(model: ReviewLog.self)
        try? ctx.save()
    }

    private func wipe() {
        try? ctx.delete(model: ReviewLog.self)
        try? ctx.delete(model: Word.self)
        try? ctx.delete(model: WordList.self)
        try? ctx.save()
    }
}

/// 設定 › AI 翻譯: translate words the dictionary doesn't know with a language model (on by default).
struct AITranslationSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var key = APIKey.value
    @State private var saved = !APIKey.value.isEmpty
    @State private var testing = false
    @State private var testResult: String?
    private var translator: WordTranslator { .shared }

    var body: some View {
        @Bindable var settings = settings
        Form { Group {
            Section {
                Toggle("AI 翻譯", isOn: $settings.aiTranslate)
                if settings.aiTranslate { LabeledContent("目前使用", value: translator.providerName) }
            } footer: {
                Text(settings.aiTranslate
                     ? "字典沒有的字用 AI 翻譯。"
                     : "改用 Apple 翻譯：較快，但只有一個意思。")
            }
            if settings.aiTranslate {
                Section {
                    TextField("API 網址", text: $settings.apiBaseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型", text: $settings.apiModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(saved ? "更新 key" : "儲存 key") {
                        APIKey.value = key; saved = !APIKey.value.isEmpty; testResult = nil
                    }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved {
                        Button(testing ? "測試中…" : "測試翻譯 serendipity") { Task { await test() } }.disabled(testing)
                        if let testResult { Text(testResult).font(.app(.footnote)).foregroundStyle(.secondary) }
                        Button("移除 key", role: .destructive) { APIKey.value = ""; key = ""; saved = false; testResult = nil }
                    }
                } header: { Text("自訂 API（選填）") } footer: {
                    Text("沒填就用裝置端 Apple Intelligence。key 只存在這台裝置。")
                }
                if translator.cache.count > 0 {
                    Section { LabeledContent("已翻譯", value: "\(translator.cache.count) 個字") }
                }
            }
        }.listRowBackground(Color.cardFill) }.themedBackground()
        .navigationTitle("AI 翻譯")
    }

    private func test() async {
        testing = true; defer { testing = false }
        do {
            let r = try await ChatAPI.translate(["serendipity"], baseURL: settings.apiBaseURL, model: settings.apiModel, key: APIKey.value)
            if let i = r["serendipity"] { testResult = "成功：\(i.pos) \(i.meanings.joined(separator: "、"))" }
            else { testResult = "格式解析失敗" }
        } catch { testResult = "失敗：\(error.localizedDescription)" }
    }
}

/// 設定 › 帳號登入: sign in with an emailed link; the backup syncs to the cloud, and share codes are listed here.
struct AccountView: View {
    @Environment(\.modelContext) private var ctx
    @State private var email = ""
    @State private var sending = false
    @State private var sentTo: String?
    @State private var code = ""
    @State private var verifying = false
    @State private var message: String?
    @State private var lists: [Cloud.SharedList] = []
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var confirmSignOut = false
    @State private var signingOut = false
    private var cloud: Cloud { .shared }

    var body: some View {
        Form { Group {
            if let s = cloud.session {
                Section {
                    LabeledContent("帳號", value: s.email)
                    Button {
                        if let id = cloud.account?.id { UIPasteboard.general.string = id; message = "已拷貝使用者 ID" }
                    } label: {
                        LabeledContent("使用者 ID") {
                            Text(cloud.account?.id ?? "讀取中…").font(.app(.body).monospaced())
                        }
                    }.tint(.primary)
                    LabeledContent("上次同步", value: cloud.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "還沒同步")
                    Button(cloud.syncing ? "同步中…" : "立即同步") {
                        Task { do { message = try await cloud.sync(ctx) } catch { message = error.localizedDescription } }
                    }.disabled(cloud.syncing)
                } footer: {
                    Text("同一個 Email 的裝置會互相同步，單字、紀錄和設定都存在帳號上。點使用者 ID 可以拷貝，回報問題或加好友時用。")
                }
                Section {
                    if lists.allSatisfy({ $0.hoursLeft == 0 }) { Text("目前沒有分享中的清單").foregroundStyle(.secondary) }
                    ForEach(lists.filter { $0.hoursLeft > 0 }) { l in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(l.name).font(.app(.headline))
                                Text("\(l.word_count) 個字・剩 \(l.hoursLeft) 小時").font(.app(.footnote)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Cloud.pretty(l.code)).font(.body.monospaced()).textSelection(.enabled)
                        }
                        .swipeActions {
                            Button("停止分享", role: .destructive) {
                                Task { try? await cloud.deleteList(l.code); await loadLists() }
                            }
                        }
                        .contextMenu { Button("拷貝代碼") { UIPasteboard.general.string = Cloud.pretty(l.code) } }
                    }
                } header: { Text("我分享的清單") } footer: {
                    Text("代碼 72 小時後失效並從雲端刪除；從清單再分享一次可以延長。左滑停止分享。")
                }
                Section {
                    Button(signingOut ? "登出中…" : "登出", role: .destructive) { confirmSignOut = true }.disabled(signingOut)
                    Button(deleting ? "刪除中…" : "刪除帳號", role: .destructive) { confirmDelete = true }.disabled(deleting)
                } footer: {
                    Text("登出前會先上傳到雲端，再把這個帳號的單字、紀錄和設定從這台裝置移除；再登入就會回來。刪除帳號會刪掉雲端上的備份和分享中的清單，這台裝置上的單字和進度會保留。")
                }
            } else {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(sentTo != nil)
                    if sentTo == nil {
                        Button(sending ? "寄送中…" : "寄驗證碼") { Task { await sendCode() } }
                            .disabled(sending || !email.contains("@") || !email.contains("."))
                    }
                } header: { Text("登入") } footer: {
                    Text("用 Email 收 6 位數驗證碼登入，資料會同步到雲端，也能參加單字對戰。")
                }
                if let sentTo {
                    Section {
                        CodeBoxes(code: $code).onChange(of: code) { _, c in if c.count == 6 { Task { await verify() } } }
                        Button(verifying ? "登入中…" : "登入") { Task { await verify() } }
                            .disabled(verifying || code.count != 6)
                        Button("重新寄驗證碼") { Task { await sendCode() } }.disabled(sending)
                        Button("換一個 Email") { self.sentTo = nil; code = "" }
                    } header: { Text("輸入驗證碼") } footer: {
                        Text("已寄到 \(sentTo)，在任何裝置上看信都可以。沒收到請查看垃圾郵件。")
                    }
                }
            }
        }.listRowBackground(Color.cardFill) }.themedBackground()
        .navigationTitle("帳號登入")
        .task { await loadLists(); if cloud.signedIn, cloud.account == nil { await cloud.loadAccount() } }
        .alert("登出？", isPresented: $confirmSignOut) {
            Button("登出", role: .destructive) {
                Task {
                    signingOut = true; defer { signingOut = false }
                    do { try await cloud.signOut(ctx); lists = [] }
                    catch { message = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會先把資料傳到雲端，再從這台裝置移除這個帳號的單字、紀錄和設定。再登入同一個帳號就會回來。")
        }
        .onChange(of: cloud.signedIn) { _, _ in Task { await loadLists() } }
        .alert("刪除帳號？", isPresented: $confirmDelete) {
            Button("刪除帳號", role: .destructive) {
                Task {
                    deleting = true; defer { deleting = false }
                    do { try await cloud.deleteAccount(); lists = []; message = "帳號已刪除" }
                    catch { message = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會永久刪除這個帳號和雲端上的所有資料，無法復原。這台裝置上的單字和進度會保留。有訂閱的話，要另外到 App Store 取消。")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        }
    }

    private func loadLists() async {
        guard cloud.signedIn else { return }
        lists = (try? await cloud.myLists()) ?? []
    }

    private func sendCode() async {
        sending = true; defer { sending = false }
        do { try await cloud.sendCode(to: email); sentTo = email.trimmingCharacters(in: .whitespaces); code = "" }
        catch { message = error.localizedDescription }
    }

    private func verify() async {
        guard let sentTo, code.count == 6, !verifying else { return }
        verifying = true; defer { verifying = false }
        do {
            try await cloud.verify(email: sentTo, code: code)
            self.sentTo = nil; code = ""
            let r = (try? await cloud.sync(ctx)) ?? ""
            message = "已登入 \(cloud.session?.email ?? "")\(r.isEmpty ? "" : "，\(r)")"
        } catch { code = ""; message = error.localizedDescription }
    }
}

/// Six boxes for the emailed sign-in code; one hidden field takes the typing (and the code iOS suggests from Mail).
struct CodeBoxes: View {
    @Binding var code: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .focused($focused).opacity(0.02).accessibilityLabel("6 位數驗證碼")
                .onChange(of: code) { _, c in
                    let d = String(c.filter(\.isNumber).prefix(6))
                    if d != c { code = d }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let ch = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                    Text(ch).font(.app(size: 24, .bold)).monospacedDigit()
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(focused && i == min(code.count, 5) ? Color.themeAccent : .clear, lineWidth: 2))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .padding(.vertical, 4)
    }
}
