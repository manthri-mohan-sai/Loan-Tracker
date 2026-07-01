import Foundation

// MARK: - Document Types

/// All loan-related document types the app can classify.
enum LoanDocumentType: String, CaseIterable, Identifiable {
    case sanctionLetter
    case loanAgreement
    case disbursementLetter
    case loanStatement
    case amortizationSchedule
    case rateChangeLetter
    case interestCertificate
    case closureLetter
    case insurancePolicy
    case collateralDocument
    case restructuringAgreement
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sanctionLetter:          return "Sanction Letter"
        case .loanAgreement:           return "Loan Agreement"
        case .disbursementLetter:      return "Disbursement Letter"
        case .loanStatement:           return "Loan Statement"
        case .amortizationSchedule:    return "Amortization Schedule"
        case .rateChangeLetter:        return "Rate Change Letter"
        case .interestCertificate:     return "Interest Certificate"
        case .closureLetter:           return "Closure / NOC Letter"
        case .insurancePolicy:         return "Insurance Policy"
        case .collateralDocument:      return "Collateral Document"
        case .restructuringAgreement:  return "Restructuring Agreement"
        case .unknown:                 return "Unknown Document"
        }
    }

    var sfSymbol: String {
        switch self {
        case .sanctionLetter:          return "doc.badge.plus"
        case .loanAgreement:           return "doc.text.fill"
        case .disbursementLetter:      return "banknote"
        case .loanStatement:           return "list.bullet.rectangle"
        case .amortizationSchedule:    return "tablecells"
        case .rateChangeLetter:        return "chart.line.uptrend.xyaxis"
        case .interestCertificate:     return "doc.richtext"
        case .closureLetter:           return "checkmark.seal"
        case .insurancePolicy:         return "shield.checkered"
        case .collateralDocument:      return "building.columns"
        case .restructuringAgreement:  return "arrow.triangle.2.circlepath"
        case .unknown:                 return "doc.questionmark"
        }
    }

    /// Whether this document type creates a new loan vs acts on an existing one.
    var createsNewLoan: Bool {
        switch self {
        case .sanctionLetter, .loanAgreement, .disbursementLetter: return true
        default: return false
        }
    }
}

// MARK: - Extracted Field Structs

/// Stage 2a: Fields for creating a new loan (sanction letter, agreement, disbursement).
struct LoanCreationFields {
    var loanName: String
    var principalAmount: Double
    var annualInterestRatePercent: Double
    var monthlyEMI: Double
    var tenureMonths: Int
    var startDate: String
    var emiDay: Int
    var bankName: String
    var rateType: String
    var prepaymentPenaltyPercent: Double
    var currencyCode: String
}

/// Stage 2b: Fields for a rate change letter.
struct RateChangeFields {
    var newRatePercent: Double
    var effectiveDate: String
    var previousRatePercent: Double
    var reason: String
    var bankName: String
}

/// Stage 2c: Fields for a loan statement.
struct LoanStatementFields {
    var outstandingBalance: Double
    var statementDate: String
    var emisPaid: Int
    var totalInterestPaid: Double
    var bankName: String
}

// MARK: - Extraction Results

struct DocumentClassificationResult {
    let documentType: LoanDocumentType
    let reasoning: String
}

/// Holds the structured extraction output for any document type.
enum ExtractedFields {
    case loanCreation(LoanCreationFields)
    case rateChange(RateChangeFields)
    case loanStatement(LoanStatementFields)
    case referenceOnly  // Insurance, collateral, etc.
}

struct DocumentExtractionResult {
    let documentType: LoanDocumentType
    let fields: ExtractedFields
    let ocrText: String
    let markdownText: String?
}

// MARK: - Extraction Protocol

/// Abstraction layer for document intelligence extraction backends.
protocol DocumentExtractor: Sendable {
    func classify(ocrText: String) async throws -> DocumentClassificationResult
    func extractLoanCreation(ocrText: String) async throws -> LoanCreationFields
    func extractRateChange(ocrText: String) async throws -> RateChangeFields
    func extractStatement(ocrText: String) async throws -> LoanStatementFields
}

extension DocumentExtractor {
    /// Convenience: classify then extract appropriate fields.
    func classifyAndExtract(ocrText: String, markdownText: String? = nil) async throws -> DocumentExtractionResult {
        let classification = try await classify(ocrText: ocrText)

        // Prefer markdown-converted text for PDFs (structured tables, clean layout).
        // Falls back to raw OCR text for images or non-PDF inputs.
        let textForExtraction = markdownText ?? ocrText

        let fields: ExtractedFields
        switch classification.documentType {
        case .sanctionLetter, .loanAgreement, .disbursementLetter:
            fields = .loanCreation(try await extractLoanCreation(ocrText: textForExtraction))
        case .rateChangeLetter, .restructuringAgreement:
            fields = .rateChange(try await extractRateChange(ocrText: textForExtraction))
        case .loanStatement:
            fields = .loanStatement(try await extractStatement(ocrText: textForExtraction))
        default:
            fields = .referenceOnly
        }

        return DocumentExtractionResult(
            documentType: classification.documentType,
            fields: fields,
            ocrText: ocrText,
            markdownText: markdownText
        )
    }
}

// MARK: - Regex-Based Extractor

/// Extracts loan details from OCR text using regex patterns.
struct RegexExtractor: DocumentExtractor {

    func classify(ocrText: String) async throws -> DocumentClassificationResult {
        let text = ocrText.lowercased()

        // Score each document type by keyword hits
        let classifiers: [(LoanDocumentType, [String])] = [
            (.sanctionLetter, ["sanction", "sanctioned amount", "facility sanctioned", "loan sanctioned", "approved amount", "sanction letter"]),
            (.loanAgreement, ["loan agreement", "agreement", "terms and conditions", "borrower agrees", "schedule of charges", "hypothecation"]),
            (.disbursementLetter, ["disbursement", "disbursed", "amount credited", "disbursal"]),
            (.rateChangeLetter, ["rate revision", "revised rate", "rate change", "new rate of interest", "revised roi", "reset of interest", "w.e.f", "with effect from"]),
            (.loanStatement, ["statement of account", "account statement", "outstanding balance", "principal outstanding", "statement", "balance as on", "account summary"]),
            (.amortizationSchedule, ["amortization", "repayment schedule", "emi schedule", "installment schedule"]),
            (.interestCertificate, ["interest certificate", "provisional certificate", "certificate of interest", "tax benefit"]),
            (.closureLetter, ["closure", "foreclosure", "no objection", "noc", "loan closed", "no dues"]),
            (.insurancePolicy, ["insurance", "policy", "premium", "sum assured", "cover note"]),
            (.collateralDocument, ["collateral", "mortgage", "property", "title deed", "valuation"]),
            (.restructuringAgreement, ["restructur", "moratorium", "rescheduled", "modified terms"]),
        ]

        var bestType: LoanDocumentType = .unknown
        var bestScore = 0
        var reasoning = "No matching keywords found"

        for (docType, keywords) in classifiers {
            let score = keywords.reduce(0) { count, keyword in
                count + (text.contains(keyword) ? 1 : 0)
            }
            if score > bestScore {
                bestScore = score
                bestType = docType
                reasoning = "Matched \(score) keyword(s) for \(docType.displayName)"
            }
        }

        // Require at least 1 keyword match; otherwise unknown
        if bestScore == 0 {
            // If we see loan-related amounts/rates but no specific doc type keywords,
            // default to sanction letter (most common import scenario)
            let hasAmount = extractAmount(from: ocrText, near: ["loan", "amount", "principal", "sanctioned", "facility"]) != nil
            let hasRate = extractRate(from: ocrText) != nil
            if hasAmount || hasRate {
                bestType = .sanctionLetter
                reasoning = "Contains loan data but no specific document type keywords; treating as loan document"
            }
        }

        return DocumentClassificationResult(documentType: bestType, reasoning: reasoning)
    }

    func extractLoanCreation(ocrText: String) async throws -> LoanCreationFields {
        let principal = extractAmount(from: ocrText, near: [
            "sanction", "principal", "loan amount", "facility", "disburs",
            "approved", "sanctioned amount", "amount"
        ]) ?? 0

        let rate = extractRate(from: ocrText) ?? 0
        let emi = extractAmount(from: ocrText, near: [
            "emi", "monthly installment", "equated monthly", "installment amount",
            "repayment amount", "monthly payment"
        ]) ?? 0

        let tenure = extractTenure(from: ocrText)
        let startDate = extractDate(from: ocrText)
        let emiDay = extractEMIDay(from: ocrText)
        let bankName = extractBankName(from: ocrText)
        let currency = extractCurrency(from: ocrText)
        let isFloating = ocrText.lowercased().contains("float") || ocrText.lowercased().contains("variable") || ocrText.lowercased().contains("adjustable")
        let isFixed = ocrText.lowercased().contains("fixed")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return LoanCreationFields(
            loanName: extractLoanType(from: ocrText) ?? "Loan",
            principalAmount: principal,
            annualInterestRatePercent: rate,
            monthlyEMI: emi,
            tenureMonths: tenure ?? 0,
            startDate: startDate.map { dateFormatter.string(from: $0) } ?? "",
            emiDay: emiDay ?? 0,
            bankName: bankName ?? "",
            rateType: isFloating ? "floating" : (isFixed ? "fixed" : ""),
            prepaymentPenaltyPercent: 0,
            currencyCode: currency ?? ""
        )
    }

    func extractRateChange(ocrText: String) async throws -> RateChangeFields {
        let newRate = extractRate(from: ocrText, near: ["new", "revised", "reset", "current"]) ?? extractRate(from: ocrText) ?? 0
        let prevRate = extractRate(from: ocrText, near: ["old", "previous", "existing", "earlier"]) ?? 0
        let date = extractDate(from: ocrText)
        let bankName = extractBankName(from: ocrText)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Try to find reason
        var reason = ""
        let text = ocrText.lowercased()
        if text.contains("repo") { reason = "Repo rate change" }
        else if text.contains("mclr") { reason = "MCLR revision" }
        else if text.contains("rbi") { reason = "RBI rate change" }
        else if text.contains("benchmark") { reason = "Benchmark rate revision" }

        return RateChangeFields(
            newRatePercent: newRate,
            effectiveDate: date.map { dateFormatter.string(from: $0) } ?? "",
            previousRatePercent: prevRate,
            reason: reason,
            bankName: bankName ?? ""
        )
    }

    func extractStatement(ocrText: String) async throws -> LoanStatementFields {
        let balance = extractAmount(from: ocrText, near: [
            "outstanding", "balance", "principal outstanding", "remaining",
            "closing balance", "balance as on"
        ]) ?? 0

        let interestPaid = extractAmount(from: ocrText, near: [
            "total interest", "interest paid", "cumulative interest",
            "interest charged", "interest component"
        ]) ?? 0

        let emisPaid = extractEMIsPaid(from: ocrText)
        let date = extractDate(from: ocrText)
        let bankName = extractBankName(from: ocrText)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return LoanStatementFields(
            outstandingBalance: balance,
            statementDate: date.map { dateFormatter.string(from: $0) } ?? "",
            emisPaid: emisPaid ?? 0,
            totalInterestPaid: interestPaid,
            bankName: bankName ?? ""
        )
    }

    // MARK: - Regex Helpers

    /// Extracts a monetary amount near the given context keywords.
    private func extractAmount(from text: String, near keywords: [String]) -> Double? {
        let lines = text.components(separatedBy: .newlines)
        var candidates: [(value: Double, distance: Int)] = []

        // Amount patterns: ₹1,25,000 / Rs. 50,00,000 / $125,000 / 1,25,000.00 / INR 5000000
        let amountPattern = #"(?:₹|Rs\.?\s*|INR\s*|USD\s*|\$|€|£|AED\s*|د\.إ\s*)?\s*(\d[\d,]+(?:\.\d{1,2})?)"#
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: .caseInsensitive) else { return nil }

        for (lineIndex, line) in lines.enumerated() {
            let lowerLine = line.lowercased()

            // Check if any keyword is on this line or nearby lines
            var minDistance = Int.max
            for keyword in keywords {
                if lowerLine.contains(keyword) {
                    minDistance = 0
                    break
                }
                // Check nearby lines (within 2 lines)
                for offset in 1...2 {
                    let nearby = [lineIndex - offset, lineIndex + offset]
                    for idx in nearby where idx >= 0 && idx < lines.count {
                        if lines[idx].lowercased().contains(keyword) {
                            minDistance = min(minDistance, offset)
                        }
                    }
                }
            }

            guard minDistance <= 2 else { continue }

            let matches = amountRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches {
                if let range = Range(match.range(at: 1), in: line) {
                    let numStr = String(line[range]).replacingOccurrences(of: ",", with: "")
                    if let value = Double(numStr), value > 100 { // Filter tiny numbers
                        candidates.append((value, minDistance))
                    }
                }
            }
        }

        // Prefer closest to keyword, then largest value
        return candidates
            .sorted { $0.distance == $1.distance ? $0.value > $1.value : $0.distance < $1.distance }
            .first?.value
    }

    /// Extracts an interest rate percentage, optionally near context keywords.
    private func extractRate(from text: String, near keywords: [String]? = nil) -> Double? {
        let lines = text.components(separatedBy: .newlines)
        let rateKeywords = keywords ?? ["interest", "roi", "rate", "r.o.i", "rate of interest", "apr", "p.a"]
        var candidates: [(value: Double, distance: Int)] = []

        // Pattern: number followed by % or "per cent" or "p.a."
        let ratePattern = #"(\d{1,2}(?:\.\d{1,4})?)\s*(?:%|per\s*cent|p\.?\s*a\.?|percent)"#
        guard let rateRegex = try? NSRegularExpression(pattern: ratePattern, options: .caseInsensitive) else { return nil }

        for (lineIndex, line) in lines.enumerated() {
            let lowerLine = line.lowercased()

            var minDistance = Int.max
            for keyword in rateKeywords {
                if lowerLine.contains(keyword) {
                    minDistance = 0
                    break
                }
                for offset in 1...2 {
                    let nearby = [lineIndex - offset, lineIndex + offset]
                    for idx in nearby where idx >= 0 && idx < lines.count {
                        if lines[idx].lowercased().contains(keyword) {
                            minDistance = min(minDistance, offset)
                        }
                    }
                }
            }

            guard minDistance <= 2 else { continue }

            let matches = rateRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches {
                if let range = Range(match.range(at: 1), in: line) {
                    if let value = Double(line[range]), value > 0.1 && value < 50 {
                        candidates.append((value, minDistance))
                    }
                }
            }
        }

        return candidates
            .sorted { $0.distance < $1.distance }
            .first?.value
    }

    /// Extracts tenure in months from text.
    private func extractTenure(from text: String) -> Int? {
        let lower = text.lowercased()

        // "240 months" or "20 years"
        let monthsPattern = #"(\d+)\s*months?"#
        let yearsPattern = #"(\d+)\s*years?"#

        if let monthsRegex = try? NSRegularExpression(pattern: monthsPattern, options: .caseInsensitive) {
            let matches = monthsRegex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            for match in matches {
                if let range = Range(match.range(at: 1), in: lower),
                   let months = Int(lower[range]),
                   months > 6 && months <= 600 {
                    return months
                }
            }
        }

        if let yearsRegex = try? NSRegularExpression(pattern: yearsPattern, options: .caseInsensitive) {
            let matches = yearsRegex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            for match in matches {
                if let range = Range(match.range(at: 1), in: lower),
                   let years = Int(lower[range]),
                   years >= 1 && years <= 50 {
                    return years * 12
                }
            }
        }

        return nil
    }

    /// Extracts a date from the text (tries multiple formats).
    private func extractDate(from text: String) -> Date? {
        // DD/MM/YYYY, DD-MM-YYYY, DD.MM.YYYY
        let datePatterns: [(String, String)] = [
            (#"(\d{2})[/\-.](\d{2})[/\-.](\d{4})"#, "dd/MM/yyyy"),
            (#"(\d{2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{4})"#, "dd MMM yyyy"),
            (#"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2}),?\s+(\d{4})"#, "MMM dd, yyyy"),
        ]

        for (pattern, _) in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let dateStr = String(text[range])
                    // Try multiple formatters
                    for fmt in ["dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yyyy", "dd MMM yyyy", "dd MMMM yyyy", "MMM dd, yyyy", "MMMM dd, yyyy"] {
                        let formatter = DateFormatter()
                        formatter.dateFormat = fmt
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        if let date = formatter.date(from: dateStr) {
                            // Sanity check: date should be between 2000 and 2040
                            let year = Calendar.current.component(.year, from: date)
                            if year >= 2000 && year <= 2040 {
                                return date
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Extracts EMI day (1-31) from text.
    private func extractEMIDay(from text: String) -> Int? {
        let lower = text.lowercased()
        let pattern = #"(?:emi|installment|repayment)\s*(?:due|debit|date)?\s*(?:on|:)?\s*(\d{1,2})(?:st|nd|rd|th)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        for match in matches {
            if let range = Range(match.range(at: 1), in: lower),
               let day = Int(lower[range]),
               (1...31).contains(day) {
                return day
            }
        }
        return nil
    }

    /// Extracts bank name by matching known Indian and international bank names.
    private func extractBankName(from text: String) -> String? {
        let knownBanks = [
            "State Bank of India", "SBI", "HDFC Bank", "HDFC", "ICICI Bank", "ICICI",
            "Axis Bank", "Kotak Mahindra", "Bank of Baroda", "Punjab National Bank", "PNB",
            "Union Bank", "Canara Bank", "Indian Bank", "Bank of India", "IDFC First",
            "Yes Bank", "IndusInd Bank", "Federal Bank", "RBL Bank", "Bandhan Bank",
            "LIC Housing", "Bajaj Housing", "Tata Capital", "IIFL", "Piramal",
            "Chase", "Wells Fargo", "Bank of America", "Citi", "Citibank",
            "HSBC", "Barclays", "Standard Chartered", "Deutsche Bank",
            "DBS Bank", "OCBC", "UOB", "Maybank", "Commonwealth Bank",
            "ANZ", "Westpac", "NAB", "TD Bank", "RBC", "Scotiabank"
        ]

        // Check first 20 lines (header area) first, then full text
        let lines = text.components(separatedBy: .newlines)
        let headerLines = lines.prefix(20).joined(separator: " ")

        for bank in knownBanks {
            if headerLines.localizedCaseInsensitiveContains(bank) {
                return bank
            }
        }
        for bank in knownBanks {
            if text.localizedCaseInsensitiveContains(bank) {
                return bank
            }
        }
        return nil
    }

    /// Detects currency from text.
    private func extractCurrency(from text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("₹") || lower.contains("inr") || lower.contains("rupee") { return "INR" }
        if lower.contains("$") || lower.contains("usd") || lower.contains("dollar") {
            if lower.contains("sgd") || lower.contains("singapore") { return "SGD" }
            if lower.contains("aud") || lower.contains("australia") { return "AUD" }
            if lower.contains("cad") || lower.contains("canad") { return "CAD" }
            return "USD"
        }
        if lower.contains("€") || lower.contains("eur") { return "EUR" }
        if lower.contains("£") || lower.contains("gbp") || lower.contains("pound") { return "GBP" }
        if lower.contains("aed") || lower.contains("dirham") { return "AED" }
        return nil
    }

    /// Extracts loan type description.
    private func extractLoanType(from text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("home loan") || lower.contains("housing loan") || lower.contains("mortgage") { return "Home Loan" }
        if lower.contains("car loan") || lower.contains("auto loan") || lower.contains("vehicle loan") { return "Car Loan" }
        if lower.contains("personal loan") { return "Personal Loan" }
        if lower.contains("education loan") || lower.contains("student loan") { return "Education Loan" }
        if lower.contains("business loan") || lower.contains("commercial") { return "Business Loan" }
        if lower.contains("gold loan") { return "Gold Loan" }
        if lower.contains("loan against property") || lower.contains("lap") { return "Loan Against Property" }
        return nil
    }

    /// Extracts number of EMIs paid from statement text.
    private func extractEMIsPaid(from text: String) -> Int? {
        let lower = text.lowercased()
        let patterns = [
            #"(\d+)\s*(?:emis?|installments?)\s*(?:paid|received|collected)"#,
            #"(?:emis?|installments?)\s*(?:paid|received)[\s:]*(\d+)"#,
            #"no\.?\s*of\s*(?:emis?|installments?)[\s:]*(\d+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            for match in matches {
                if let range = Range(match.range(at: 1), in: lower),
                   let count = Int(lower[range]),
                   count > 0 && count < 1000 {
                    return count
                }
            }
        }
        return nil
    }
}


// MARK: - Extractor Factory

enum DocumentExtractorFactory {
    static func makeExtractor() -> DocumentExtractor {
        RegexExtractor()
    }
}
