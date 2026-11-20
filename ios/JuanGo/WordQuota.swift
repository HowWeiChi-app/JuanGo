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

    // MARK: Over the limit: warn, then delete the words added first

    /// Days of warning before the extra words are deleted, and the shorter one for a second countdown within 90 days.
    static let grace = 30, repeatGrace = 7, repeatWindow = 90

    /// Where the countdown stands. Days are whole local days counted from 1970-01-01.
    struct Countdown: Codable, Equatable {
        var overSince: Int? = nil
        var deleteOn: Int? = nil
        /// the day the last countdown started, for the 90-day rule
        var lastStart: Int? = nil
        var shown7 = false
        var shown1 = false
    }

    /// Starts the countdown on the first day over the limit and cancels it once back under it or on Pro.
    static func countdown(_ c: Countdown, used: Int, unlimited: Bool, today: Int) -> Countdown {
        var c = c
        if unlimited || used <= limit {
            c.overSince = nil; c.deleteOn = nil; c.shown7 = false; c.shown1 = false
            return c
        }
        guard c.overSince == nil else { return c }
        let again = c.lastStart.map { today - $0 < repeatWindow } ?? false
        c.overSince = today
        c.deleteOn = today + (again ? repeatGrace : grace)
        c.lastStart = today
        return c
    }

    /// Days left when the app should pop up a reminder now (7, then 1), or nil.
    static func reminder(_ c: Countdown, today: Int) -> Int? {
        guard let end = c.deleteOn, today < end else { return nil }
        let left = end - today
        if left <= 1 { return c.shown1 ? nil : 1 }
        if left <= 7 { return c.shown7 ? nil : 7 }
        return nil
    }

    static func due(_ c: Countdown, today: Int) -> Bool { c.deleteOn.map { today >= $0 } ?? false }

    /// How many of the counted words go: down to exactly the limit.
    static func over(_ used: Int) -> Int { max(0, used - limit) }
}

