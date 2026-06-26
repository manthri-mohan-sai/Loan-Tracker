import Foundation
import PDFKit

// MARK: - PDF to Markdown (On-Device)

/// Converts PDF documents to markdown text using on-device extraction only.
/// This service intentionally has no network dependencies.
enum MarkdownConversion {

    struct Result {
        let markdownText: String
        let rawText: String
        let documentType: DocumentType
        let extractionMethod: ExtractionMethod
    }

    enum DocumentType {
        case repaymentSchedule
        case sanctionLetter
        case unknown
    }

    enum ExtractionMethod {
        case pdfKit
        case ocr
    }

    enum ConversionError: LocalizedError {
        case invalidPDF
        case emptyText
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPDF: return "Only PDF files are supported."
            case .emptyText: return "No text could be extracted from this PDF."
            case .fileTooLarge: return "PDF exceeds the 50MB limit."
            }
        }
    }

    private static let maxPDFBytes: Int64 = 50 * 1024 * 1024

    // MARK: - Entry Point

    static func convertPDF(at url: URL) async throws -> Result {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw ConversionError.invalidPDF
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let bytes = values?.fileSize, Int64(bytes) > maxPDFBytes {
            throw ConversionError.fileTooLarge
        }

        // Try PDFKit first (digital PDF — fast, free, no OCR needed)
        if let pdfText = extractWithPDFKit(at: url), !pdfText.isEmpty {
            return buildResult(rawText: pdfText, method: .pdfKit)
        }

        // Fall back to OCR (scanned PDF)
        let ocrText = try await OCRService.extractText(from: url)
        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversionError.emptyText }

        return buildResult(rawText: trimmed, method: .ocr)
    }

    // MARK: - PDFKit Extraction

    private static func extractWithPDFKit(at url: URL) -> String? {
        guard let pdf = PDFDocument(url: url) else { return nil }

        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            if let pageText = pdf.page(at: i)?.string, !pageText.isEmpty {
                pages.append(pageText)
            }
        }

        let combined = pages.joined(separator: "\n--- Page Break ---\n")

        // If less than 50 chars per page on average, likely scanned
        let avgChars = combined.count / max(pdf.pageCount, 1)
        guard avgChars > 50 else { return nil }

        return combined
    }

    // MARK: - Result Builder

    private static func buildResult(rawText: String, method: ExtractionMethod) -> Result {
        let docType = detectDocumentType(rawText)
        let markdown = formatAsMarkdown(rawText, type: docType)
        return Result(
            markdownText: markdown,
            rawText: rawText,
            documentType: docType,
            extractionMethod: method
        )
    }

    // MARK: - Document Type Detection

    private static func detectDocumentType(_ text: String) -> DocumentType {
        let lower = text.lowercased()

        let repaymentKeywords = ["repayment schedule", "emi schedule", "instl. num",
                                  "opening principal", "closing principal", "due date"]
        let sanctionKeywords  = ["sanction letter", "loan sanctioned", "sanctioned amount",
                                  "terms and conditions", "disbursement"]

        let repaymentScore = repaymentKeywords.filter { lower.contains($0) }.count
        let sanctionScore  = sanctionKeywords.filter  { lower.contains($0) }.count

        if repaymentScore >= 2 { return .repaymentSchedule }
        if sanctionScore  >= 2 { return .sanctionLetter }
        return .unknown
    }

    // MARK: - Markdown Formatting

    private static func formatAsMarkdown(_ text: String, type: DocumentType) -> String {
        let pages = text
            .components(separatedBy: "--- Page Break ---")
            .map { normalize($0) }
            .filter { !$0.isEmpty }

        var lines: [String] = []

        switch type {
        case .repaymentSchedule:
            lines.append("# Repayment Schedule\n")
            for page in pages {
                lines.append(formatRepaymentPage(page))
                lines.append("")
            }

        case .sanctionLetter:
            lines.append("# Sanction Letter\n")
            for (i, page) in pages.enumerated() {
                if pages.count > 1 { lines.append("## Page \(i + 1)\n") }
                lines.append(page)
                lines.append("")
            }

        case .unknown:
            lines.append("# Converted PDF\n")
            for page in pages {
                lines.append(page)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Repayment Page Formatter
    //
    // Strategy: detect table rows and column headers, wrap in XML-style
    // tags so the LLM can understand structure regardless of bank format.
    // We do NOT parse columns ourselves — column order varies per bank.

    private static func formatRepaymentPage(_ text: String) -> String {
        var output: [String] = []
        var tableLines: [String] = []
        var inTable = false
        var headerCaptured = false

        // Flexible pattern: installment number + any date format
        // Handles: DD/MM/YYYY, DD-MM-YYYY, DD-MMM-YYYY, MM/DD/YYYY
        let emiRowPattern = try? NSRegularExpression(
            pattern: #"^\d+\s+\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}"#
        )

        // Column header detection keywords — covers most Indian banks
        let headerKeywords = ["due date", "instl", "principal", "interest",
                              "emi", "balance", "opening", "closing", "amount"]

        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let lower = trimmed.lowercased()

            // Detect column header row (3+ keyword matches)
            let keywordMatchCount = headerKeywords.filter { lower.contains($0) }.count
            if keywordMatchCount >= 3 && !headerCaptured {
                output.append("<emi_table_header>")
                output.append(trimmed)
                output.append("</emi_table_header>")
                headerCaptured = true
                continue
            }

            // Detect EMI data row
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let isEMIRow = emiRowPattern?.firstMatch(in: trimmed, range: range) != nil

            if isEMIRow {
                if !inTable { inTable = true }
                tableLines.append(trimmed)
            } else {
                // Flush table if we've moved past it
                if inTable && !tableLines.isEmpty {
                    output.append("<emi_table>")
                    output.append(contentsOf: tableLines)
                    output.append("</emi_table>")
                    tableLines = []
                    inTable = false
                }
                output.append(trimmed)
            }
        }

        // Flush if table runs to end of page
        if !tableLines.isEmpty {
            output.append("<emi_table>")
            output.append(contentsOf: tableLines)
            output.append("</emi_table>")
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Normalize

    private static func normalize(_ text: String) -> String {
        let normalizedNewlines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalizedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var output: [String] = []
        var previousWasEmpty = false

        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty {
                    output.append("")
                    previousWasEmpty = true
                }
            } else {
                output.append(line)
                previousWasEmpty = false
            }
        }

        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
