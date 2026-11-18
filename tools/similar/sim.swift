// Similar words for each dictionary entry: words sharing a Chinese meaning in our own dictionary
// first, then the nearest neighbours in Apple's English word embedding (NaturalLanguage, on the Mac,
// no download), all of the same part of speech, in the dictionary with a Chinese meaning, and not a
// form of the same word (decide / decision). The embedding can't tell an opposite from a synonym
// (reluctant / eager), so the card shows each one's meaning beside it.
//
//   swift tools/similar/sim.swift ios/JuanGo/words.json > /tmp/sim.json
//
// Prints {"word": ["a", "b", "c"], ...}; tools/similar/merge.py writes it into words.json as "sim".
import Foundation
import NaturalLanguage

struct Entry: Decodable { let w: String; let pos: String; let zh: [String]; let lv: String }

let path = CommandLine.arguments[1]
let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
guard let emb = NLEmbedding.wordEmbedding(for: .english) else { fatalError("no English embedding") }

let usable = entries.filter { !$0.zh.isEmpty && !$0.w.contains(" ") && $0.w.count > 1 }
var byWord: [String: Entry] = [:]
for e in usable where byWord[e.w.lowercased()] == nil { byWord[e.w.lowercased()] = e }

func tags(_ pos: String) -> Set<String> {
    Set(pos.split(separator: "/").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "() ")) })
}
/// decide / decision / decided, happy / unhappy: one stem, not a similar word
func sameStem(_ a: String, _ b: String) -> Bool {
    let n = min(a.count, b.count)
    let common = zip(a, b).prefix { $0 == $1 }.count
    if common >= max(4, n - 2) { return true }
    for p in ["un", "in", "im", "dis", "non", "ir", "il", "mis", "re"] {
        if a == p + b || b == p + a { return true }
    }
    return a.contains(b) || b.contains(a)
}

// words that share a Chinese meaning: real synonyms by our own dictionary
var byMeaning: [String: [Entry]] = [:]
for e in usable { for z in e.zh { byMeaning[z, default: []].append(e) } }

/// a 大考 word (levels 1–6) reads better as a similar word than a rare one (avouch, plainspoken)
func common(_ e: Entry) -> Double { ["1", "2", "3", "4", "5", "6"].contains(e.lv) ? 0.15 : 0 }

var out: [String: [String]] = [:]
for e in usable {
    let w = e.w.lowercased()
    guard out[w] == nil else { continue }
    let myTags = tags(e.pos)
    var score: [String: Double] = [:]
    // a shared meaning counts most; the embedding orders them (closer first) and adds near neighbours
    for z in e.zh { for o in byMeaning[z] ?? [] {
        let n = o.w.lowercased()
        guard n != w, !sameStem(w, n), !myTags.isDisjoint(with: tags(o.pos)) else { continue }
        let d = emb.contains(n) && emb.contains(w) ? emb.distance(between: w, and: n) : 0.9
        score[o.w] = min(score[o.w] ?? .infinity, d - 0.6 - common(o))
    } }
    for (n, d) in emb.neighbors(for: w, maximumCount: 40) {
        guard d < 0.85, let o = byWord[n], n != w, !sameStem(w, n), !myTags.isDisjoint(with: tags(o.pos)) else { continue }
        score[o.w] = min(score[o.w] ?? .infinity, d - common(o))
    }
    let top = score.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(3).map(\.key)
    if !top.isEmpty { out[w] = Array(top) }
}

let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardError.write("\(out.count) of \(usable.count) words have similar words\n".data(using: .utf8)!)
