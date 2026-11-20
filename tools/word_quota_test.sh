#!/bin/sh
# Checks ios/JuanGo/WordQuota.swift against tools/word_quota_cases.json (Android: app/test/word_quota_test.dart).
#   sh tools/word_quota_test.sh
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
let examLevels = ["1", "2", "3", "4", "5", "6"]
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try! JSONSerialization.jsonObject(with: data) as! [String: [[String: Any]]]
var failed = 0
func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL", what) } }
for c in cases["counts"]! {
    let got = WordQuota.counts(cefr: c["cefr"] as! String, fromExam: c["fromExam"] as! Bool, inMyWords: c["inMyWords"] as! Bool,
                               favorite: c["favorite"] as! Bool, inList: c["inList"] as! Bool)
    check(got == c["counts"] as! Bool, "counts: \(c["note"]!)")
}
for c in cases["fit"]! {
    let got = WordQuota.fit(c["wanted"] as! [Bool], used: c["used"] as! Int, unlimited: c["unlimited"] as! Bool)
    check(got == c["allowed"] as! [Bool], "fit: \(c["note"]!) got \(got)")
}
for c in cases["usage"]! {
    let got = WordQuota.usage(c["used"] as! Int, unlimited: c["unlimited"] as! Bool)
    check(got == c["text"] as? String, "usage \(c["used"]!): got \(got ?? "nil")")
}
func countdown(_ j: [String: Any]) -> WordQuota.Countdown {
    WordQuota.Countdown(overSince: j["overSince"] as? Int, deleteOn: j["deleteOn"] as? Int, lastStart: j["lastStart"] as? Int,
                        shown7: j["shown7"] as? Bool ?? false, shown1: j["shown1"] as? Bool ?? false)
}
for c in cases["countdown"]! {
    let note = c["note"] as! String, today = c["today"] as! Int
    let got = WordQuota.countdown(countdown(c["before"] as! [String: Any]), used: c["used"] as! Int,
                                  unlimited: c["unlimited"] as! Bool, today: today)
    check(got == countdown(c["after"] as! [String: Any]), "countdown: \(note) got \(got)")
    check(WordQuota.reminder(got, today: today) == c["reminder"] as? Int, "reminder: \(note)")
    check(WordQuota.due(got, today: today) == c["due"] as! Bool, "due: \(note)")
}
let total = cases.values.map(\.count).reduce(0, +)
print(failed == 0 ? "WordQuota: \(total) 個案例都通過" : "WordQuota: \(failed) 個失敗")
exit(failed == 0 ? 0 : 1)
SWIFT
swiftc -O -o "$tmp/t" ios/JuanGo/WordQuota.swift "$tmp/main.swift"
"$tmp/t" tools/word_quota_cases.json
