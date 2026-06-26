import Foundation

// MARK: - PDF to Markdown (On-Device)

/// Converts PDF documents to markdown text using on-device extraction only.
/// This service intentionally has no network dependencies.
enum MarkdownConvertion {

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
            case .invalidPDF:
                return "Only PDF files are supported for markdown conversion."
            case .emptyText:
                return "No text was found in the PDF to convert."
            case .fileTooLarge:
                return "The PDF is too large to process on device."
            }
        }
    }

    // Keep conversion bounded for predictable on-device performance.
    private static let maxPDFBytes: Int64 = 50 * 1024 * 1024

    static func convertPDF(at url: URL) async throws -> Result {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw ConversionError.invalidPDF
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let bytes = values?.fileSize, Int64(bytes) > maxPDFBytes {
            throw ConversionError.fileTooLarge
        }

        let extracted = try await OCRService.extractText(from: url)
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConversionError.emptyText
        }

        let markdown = formatAsMarkdown(trimmed)
        return Result(markdownText: markdown, rawText: trimmed)
    }

    private static func formatAsMarkdown(_ text: String) -> String {
        let pageBreakToken = "--- Page Break ---"
        let pages = text
            .components(separatedBy: pageBreakToken)
            .map { normalize($0) }
            .filter { !$0.isEmpty }

        guard !pages.isEmpty else {
            return "# Converted PDF\n"
        }

        var lines: [String] = ["# Converted PDF", ""]

        if pages.count == 1 {
            lines.append(pages[0])
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for (index, page) in pages.enumerated() {
            lines.append("## Page \(index + 1)")
            lines.append("")
            lines.append(page)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func normalize(_ text: String) -> String {
        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
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

        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
