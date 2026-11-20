import SwiftUI

/// 回報單字問題 (supabase/word_reports.sql). Reports wait on this device until they reach the server,
/// so one made offline is sent later, and each carries its own id so a resend counts once.
enum WordReport {
    struct Kind: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let kinds: [Kind] = [
        .init(id: "meaning", label: "中文解釋錯誤"),
        .init(id: "ipa", label: "音標錯誤"),
        .init(id: "pos", label: "詞性錯誤"),
        .init(id: "example", label: "例句錯誤或不通順"),
        .init(id: "example_zh", label: "例句翻譯錯誤"),
        .init(id: "audio", label: "發音錯誤"),
        .init(id: "similar", label: "相似字詞不對"),
        .init(id: "level", label: "分級錯誤"),
        .init(id: "other", label: "其他"),
    ]
    static let noteLimit = 200

    private static let queueKey = "wordReports.pending"
    private static let deviceKey = "wordReports.device"

    /// A random id for this install, so people who aren't signed in can't report the same thing all day.
    private static var device: String {
        if let d = UserDefaults.standard.string(forKey: deviceKey) { return d }
        let d = UUID().uuidString
        UserDefaults.standard.set(d, forKey: deviceKey)
        return d
    }

    /// What the word page shows right now, sent with the report.
    static func snapshot(_ w: Word) -> [String: Any] {
        ["term": w.term, "meanings": w.meanings, "pos": w.pos, "ipa": w.ipa, "definition": w.definition,
         "example": w.example, "example_zh": w.exampleZh, "level": w.cefr]
    }

    private static var pending: [[String: Any]] {
        get { (UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: queueKey) }
    }

    /// Queues the report and tries to send it. True when it reached the server now.
    static func submit(word: String, kind: String, note: String, snapshot: [String: Any]) async -> Bool {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let args: [String: Any] = [
            "p_client_id": UUID().uuidString, "p_word": word, "p_exam_ref": NSNull(), "p_kind": kind,
            "p_note": String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteLimit)),
            "p_snapshot": snapshot, "p_app_version": version, "p_platform": "ios", "p_device": device,
        ]
        pending.append(args)
        let before = pending.count
        await flush()
        return pending.count < before
    }

    private static var flushing = false

    /// Sends whatever is waiting; called after a report and whenever the app comes back.
    static func flush() async {
        guard !flushing, !pending.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        for args in pending {
            guard (try? await Cloud.shared.reportWord(args)) != nil else { return }   // offline: try again later
            pending.removeAll { ($0["p_client_id"] as? String) == (args["p_client_id"] as? String) }
        }
    }
}

/// The sheet: pick what's wrong, add a line if you like, send.
struct WordReportSheet: View {
    let word: Word
    @Environment(\.dismiss) private var dismiss
    @State private var kind: WordReport.Kind?
    @State private var note = ""
    @State private var sending = false
    @State private var done: String?

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    ForEach(WordReport.kinds) { k in
                        Button { kind = k } label: {
                            HStack {
                                Text(k.label).foregroundStyle(.primary)
                                Spacer()
                                if kind == k { LIcon("checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: { Text("「\(word.term)」哪裡有問題？") }
                Section {
                    TextField("補充說明（選填）", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .onChange(of: note) { if note.count > WordReport.noteLimit { note = String(note.prefix(WordReport.noteLimit)) } }
                } footer: {
                    Text("會一起送出這個字目前的解釋、例句和音標，以及 App 版本。\(note.count) / \(WordReport.noteLimit)")
                }
            }.listRowBackground(Color.cardFill) }
            .font(.app(.body))
            .themedBackground()
            .navigationTitle("回報問題")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送出") { send() }.disabled(kind == nil || sending)
                }
            }
            .alert(done ?? "", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil; dismiss() } })) {
                Button("好") { done = nil; dismiss() }
            }
        }
    }

    private func send() {
        guard let kind else { return }
        sending = true
        let snapshot = WordReport.snapshot(word)
        Task {
            let sent = await WordReport.submit(word: word.term, kind: kind.id, note: note, snapshot: snapshot)
            sending = false
            done = sent ? "已送出，謝謝你的回報" : "目前沒有網路，連上網路後會自動送出"
        }
    }
}
