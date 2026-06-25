import Vision
import UIKit
import PDFKit

// MARK: - OCR Service

/// Extracts text from images and PDFs using Apple's Vision framework.
/// All processing is on-device — no data leaves the user's phone.
enum OCRService {

    /// Extract text from an array of scanned UIImages (from camera).
    static func recognizeText(in images: [UIImage]) async throws -> String {
        var pages: [String] = []

        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let text = try await recognizeText(in: cgImage)
            if !text.isEmpty {
                pages.append(text)
            }
        }

        guard !pages.isEmpty else { throw OCRError.noTextFound }
        return pages.joined(separator: "\n\n--- Page Break ---\n\n")
    }

    /// Extract text from a file URL (PDF or image).
    static func extractText(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return try await extractTextFromPDF(url: url)
        } else {
            // Assume image
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                throw OCRError.invalidFile
            }
            let text = try await recognizeText(in: cgImage)
            guard !text.isEmpty else { throw OCRError.noTextFound }
            return text
        }
    }

    // MARK: - Private

    /// Run VNRecognizeTextRequest on a single CGImage.
    private static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Extract text from a PDF. Tries native text first (digital PDFs),
    /// falls back to Vision OCR for scanned PDFs.
    private static func extractTextFromPDF(url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw OCRError.invalidFile
        }

        var pages: [String] = []

        for pageIndex in 0..<min(document.pageCount, 20) {
            guard let page = document.page(at: pageIndex) else { continue }

            // Try native text extraction first (digital PDFs have embedded text)
            if let pageText = page.string,
               !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(pageText)
            } else {
                // Scanned PDF — render to image and OCR
                let pageRect = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0  // Render at 2x for better OCR accuracy
                let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

                let renderer = UIGraphicsImageRenderer(size: scaledSize)
                let image = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(CGRect(origin: .zero, size: scaledSize))
                    ctx.cgContext.scaleBy(x: scale, y: scale)
                    ctx.cgContext.translateBy(x: 0, y: pageRect.height)
                    ctx.cgContext.scaleBy(x: 1, y: -1)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                if let cgImage = image.cgImage {
                    let text = try await recognizeText(in: cgImage)
                    if !text.isEmpty {
                        pages.append(text)
                    }
                }
            }
        }

        guard !pages.isEmpty else { throw OCRError.noTextFound }
        return pages.joined(separator: "\n\n--- Page Break ---\n\n")
    }

    // MARK: - Errors

    enum OCRError: LocalizedError {
        case invalidFile
        case noTextFound

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "The file could not be read."
            case .noTextFound: return "No text was found in the document."
            }
        }
    }
}
