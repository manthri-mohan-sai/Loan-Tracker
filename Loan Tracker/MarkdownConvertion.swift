import Foundation
import PDFKit

// MARK: - PDF to Markdown (On-Device)

/// Converts a PDF to plain markdown using PDFKit (digital PDFs) or OCR
/// (scanned PDFs) as a fallback. No special tags are added.
enum MarkdownConversion {

    struct Result {
        let markdownText: String
        let rawText: String
    }

    enum ConversionError: LocalizedError {
        case invalidPDF
        case emptyText
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPDF:   return "Only PDF files are supported."
            case .emptyText:    return "No text could be extracted from this PDF."
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

        // PDFKit — works for digital PDFs (fast, no network)
        if let pages = extractPages(at: url) {
            return buildResult(pages: pages)
        }

        // OCR fallback — for scanned/image-based PDFs
        let ocrText = try await OCRService.extractText(from: url)
        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversionError.emptyText }
        return buildResult(pages: [trimmed])
    }

    // MARK: - PDFKit Extraction

    private static func extractPages(at url: URL) -> [String]? {
        guard let pdf = PDFDocument(url: url) else { return nil }

        let pages = (0..<pdf.pageCount).compactMap { i -> String? in
            guard let text = pdf.page(at: i)?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // If less than 50 chars per page on average, likely scanned — use OCR instead
        guard !pages.isEmpty,
              pages.joined().count / max(pdf.pageCount, 1) > 50 else { return nil }

        return pages
    }

    // MARK: - Result Builder

    private static func buildResult(pages: [String]) -> Result {
        let rawText = pages.joined(separator: "\n\n")

        let markdownText: String
        if pages.count == 1 {
            markdownText = pages[0]
        } else {
            markdownText = pages.enumerated()
                .map { i, page in "## Page \(i + 1)\n\n\(page)" }
                .joined(separator: "\n\n---\n\n")
        }

        return Result(markdownText: markdownText, rawText: rawText)
    }
}
