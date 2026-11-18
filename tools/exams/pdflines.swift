// Prints a PDF's lines as JSON with their position (macOS PDFKit, no install):
// [{"p": page, "x": left, "y": top, "w": width, "t": text}], top-down, so paragraph indents and table cells survive.
//   swift tools/exams/pdflines.swift file.pdf > file.json
import Foundation
import PDFKit
guard let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else { fatalError("can't open") }
var out: [[String: Any]] = []
for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i), let all = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
    let h = page.bounds(for: .mediaBox).height
    for line in all.selectionsByLine() {
        let b = line.bounds(for: page), t = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { continue }
        out.append(["p": i + 1, "x": (b.minX * 10).rounded() / 10, "y": ((h - b.maxY) * 10).rounded() / 10, "w": (b.width * 10).rounded() / 10, "t": t])
    }
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out, options: []))
