import Foundation

/// The free version's 1,000-word limit. Android has the same rule in word_quota.dart;
/// both are checked against tools/word_quota_cases.json.
/// Only Foundation here, so tools/word_quota_test.sh can compile it on its own.
enum WordQuota {
    static let limit = 1000
    /// 「已用 x / 1000」 shows from this many words on
    static let showFrom = 900
    static let fullMessage = "免費版最多 1000 個單字，升級 Pro 就沒有上限"

    /// Whether a saved word takes one of the 1,000 places: it is in 我的單字, 喜歡 or one of the user's lists,
    /// and is neither 大考 vocabulary (level 1–6) nor a word added from an exam's missed words.
    static func counts(cefr: String, fromExam: Bool, inMyWords: Bool, favorite: Bool, inList: Bool) -> Bool {
        (inMyWords || favorite || inList) && !fromExam && !examLevels.contains(cefr)
    }

    /// Which of the words being added may go in, in order. `wanted[i]` is whether word i would take a new place;
    /// words that don't always go in, the others until the places run out.
    static func fit(_ wanted: [Bool], used: Int, unlimited: Bool) -> [Bool] {
        if unlimited { return wanted.map { _ in true } }
        var room = max(0, limit - used)
        return wanted.map { takes in
            guard takes else { return true }
            guard room > 0 else { return false }
            room -= 1
            return true
        }
    }

    /// 「已用 x / 1000」, or nil while there is no need to show it.
    static func usage(_ used: Int, unlimited: Bool) -> String? {
        unlimited || used < showFrom ? nil : "已用 \(used) / \(limit)"
    }

    // MARK: Over the limit (e.g. after Pro ends): read-only, nothing is deleted

    /// How many counted words are over the limit.
    static func over(_ used: Int) -> Int { max(0, used - limit) }

    static let overMessage = "單字都會保留，可以照常瀏覽和複習；只是暫停新增，刪到 1000 個以內或訂閱 Pro 就能再加。"
}

