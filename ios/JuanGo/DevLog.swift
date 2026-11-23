import SwiftUI
import UIKit

// MARK: - Log (dev build)

/// A small log kept on this iPhone for the dev build: launches, failed server calls, sync and scan results.
/// Nothing leaves the phone until the tester sends it with 「回報問題」 (開發者選項).
nonisolated enum DevLog {
    private static let queue = DispatchQueue(label: "JuanGo.devlog")
    private static let maxLines = 2000
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("devlog.txt")
    }
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    /// Adds one line, e.g. `DevLog.add("cloud", "POST rest/v1/pages → 403 …")`. Only the dev build records.
    static func add(_ tag: String, _ message: String) {
        guard DevFlags.gosPro else { return }
        let line = "\(stamp.string(from: .now)) [\(tag)] \(message.replacingOccurrences(of: "\n", with: " "))\n"
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
            trimIfNeeded()
        }
    }

    nonisolated(unsafe) private static var writes = 0
    private static func trimIfNeeded() {
        writes += 1
        guard writes % 100 == 0, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxLines else { return }
        try? (lines.suffix(maxLines).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func read() -> String {
        queue.sync { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    /// app version, build, iPhone model and iOS version, for the report and the launch line
    @MainActor static var deviceSummary: String {
        let info = Bundle.main.infoDictionary
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "JuanGo \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) · \(model) · iOS \(UIDevice.current.systemVersion)"
    }
}

// MARK: - Screens in 開發者選項

struct DevLogView: View {
    @State private var text = ""
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "還沒有紀錄。" : text)
                .font(.app(.caption)).monospaced()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .themedBackground()
        .navigationTitle("Log 紀錄")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清除", role: .destructive) { confirmClear = true }.disabled(text.isEmpty)
            }
        }
        .alert("清除這支手機上的 log？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { DevLog.clear(); text = "" }
            Button("取消", role: .cancel) {}
        }
        .task { text = DevLog.read() }
    }
}

struct DevReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var withLog = true
    @State private var sending = false
    @State private var result: String?
    @State private var sent = false
    @FocusState private var typing: Bool

    var body: some View {
        Form { Group {
            Section {
                TextField("哪裡怪怪的？怎麼發生的？", text: $message, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($typing)
            } footer: {
                Text("會一起送出：\(DevLog.deviceSummary)")
            }
            Section {
                Toggle("附上 log 紀錄", isOn: $withLog)
                NavigationLink("看看要送出的 log") { DevLogView() }
            } footer: {
                Text("Log 只有在按「送出」時才會上傳，平常都只存在這支手機。")
            }
            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack { Text(sending ? "送出中…" : "送出"); if sending { Spacer(); ProgressView() } }
                }
                .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.listRowBackground(Color.cardFill) }
        .font(.app(.body))
        .themedBackground()
        .navigationTitle("回報問題")
        .navigationBarTitleDisplayMode(.inline)
        .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("好", role: .cancel) { if sent { dismiss() } }
        }
        .onAppear { typing = true }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        typing = false
        let info = Bundle.main.infoDictionary
        DevLog.add("report", "sending a report")
        let row: [String: Any] = [
            "app": "juango", "platform": "ios",
            "version": info?["CFBundleShortVersionString"] as? String ?? "",
            "build": info?["CFBundleVersion"] as? String ?? "",
            "device": DevLog.deviceSummary,
            "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
            "log": withLog ? String(DevLog.read().suffix(200_000)) : "",
        ]
        do {
            let body = try JSONSerialization.data(withJSONObject: row)
            _ = try await Cloud.shared.sendRaw(CloudConfig.url.appendingPathComponent("rest/v1/dev_reports"), method: "POST",
                                               body: body, prefer: "return=minimal")
            sent = true
            message = ""
            result = "已送出，謝謝回報！"
        } catch {
            let text = error.localizedDescription
            result = text.contains("dev_reports") || text.contains("relation") ? "回報的伺服器還沒開通。" : "沒有送出：\(text)"
        }
    }
}
