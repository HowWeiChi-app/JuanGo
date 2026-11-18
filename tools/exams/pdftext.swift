// Prints a PDF's text, page by page, with macOS PDFKit (no install).
//   swift tools/exams/pdftext.swift file.pdf > file.txt
import Foundation
import PDFKit
guard let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else { fatalError("can't open") }
for i in 0..<doc.pageCount { print("=== page \(i + 1)"); print(doc.page(at: i)?.string ?? "") }
