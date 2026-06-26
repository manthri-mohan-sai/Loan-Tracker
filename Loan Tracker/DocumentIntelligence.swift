import Foundation
import FoundationModels
import CoreML

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

// MARK: - @Generable Structs for FoundationModels

/// Stage 1: Document classification.
@Generable(description: "Classification of a scanned loan document")
struct DocumentClassificationOutput {
    @Guide(description: "The type of loan document. Must be one of: sanctionLetter, loanAgreement, disbursementLetter, loanStatement, amortizationSchedule, rateChangeLetter, interestCertificate, closureLetter, insurancePolicy, collateralDocument, restructuringAgreement, unknown")
    var documentType: String

    @Guide(description: "Brief reason for the classification in one short sentence")
    var reasoning: String
}

/// Stage 2a: Fields for creating a new loan (sanction letter, agreement, disbursement).
@Generable(description: "Fields extracted from a loan sanction letter or agreement")
struct LoanCreationFields {
    @Guide(description: "Name or description of the loan, e.g. 'Home Loan'")
    var loanName: String

    @Guide(description: "Sanctioned or principal loan amount as a number")
    var principalAmount: Double

    @Guide(description: "Annual interest rate as a percentage number, e.g. 8.5 for 8.5%")
    var annualInterestRatePercent: Double

    @Guide(description: "Monthly EMI or installment amount")
    var monthlyEMI: Double

    @Guide(description: "Loan tenure in months")
    var tenureMonths: Int

    @Guide(description: "Loan start or disbursement date as YYYY-MM-DD")
    var startDate: String

    @Guide(description: "Day of month when EMI is debited, 1 to 31")
    var emiDay: Int

    @Guide(description: "Name of the lending bank or institution")
    var bankName: String

    @Guide(description: "Whether the rate is floating or fixed. Use 'floating' or 'fixed'")
    var rateType: String

    @Guide(description: "Prepayment penalty as a percentage, 0 if none")
    var prepaymentPenaltyPercent: Double

    @Guide(description: "ISO 4217 currency code like INR, USD, EUR, GBP")
    var currencyCode: String
}

/// Stage 2b: Fields for a rate change letter.
@Generable(description: "Fields extracted from a rate change notification letter")
struct RateChangeFields {
    @Guide(description: "New annual interest rate as a percentage number")
    var newRatePercent: Double

    @Guide(description: "Effective date of the rate change as YYYY-MM-DD")
    var effectiveDate: String

    @Guide(description: "Previous annual interest rate as a percentage, 0 if not mentioned")
    var previousRatePercent: Double

    @Guide(description: "Reason for rate change if mentioned, empty string otherwise")
    var reason: String

    @Guide(description: "Name of the bank")
    var bankName: String
}

/// Stage 2c: Fields for a loan statement.
@Generable(description: "Fields extracted from a loan statement")
struct LoanStatementFields {
    @Guide(description: "Outstanding or remaining balance as of the statement date")
    var outstandingBalance: Double

    @Guide(description: "Statement date as YYYY-MM-DD")
    var statementDate: String

    @Guide(description: "Number of EMIs paid so far, 0 if not mentioned")
    var emisPaid: Int

    @Guide(description: "Total interest paid so far, 0 if not mentioned")
    var totalInterestPaid: Double

    @Guide(description: "Name of the bank")
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

/// Abstraction layer for document intelligence. Both FoundationModels and
/// a downloaded CoreML model can conform to this protocol.
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

        let fields: ExtractedFields
        switch classification.documentType {
        case .sanctionLetter, .loanAgreement, .disbursementLetter:
            fields = .loanCreation(try await extractLoanCreation(ocrText: ocrText))
        case .rateChangeLetter, .restructuringAgreement:
            fields = .rateChange(try await extractRateChange(ocrText: ocrText))
        case .loanStatement:
            fields = .loanStatement(try await extractStatement(ocrText: ocrText))
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

// MARK: - FoundationModels Implementation

/// Uses Apple Intelligence on-device LLM for document classification and extraction.
struct FoundationModelsExtractor: DocumentExtractor {

    func classify(ocrText: String) async throws -> DocumentClassificationResult {
        let session = LanguageModelSession(instructions: """
            You are a financial document classifier for a loan tracking app.

            TASK: Read the OCR text below and output EXACTLY ONE of these document type values:
            - sanctionLetter (bank approves/sanctions a loan — contains sanctioned amount, terms)
            - loanAgreement (formal contract between borrower and lender — terms & conditions, schedules)
            - disbursementLetter (confirms money has been disbursed/credited to borrower)
            - loanStatement (periodic account statement showing outstanding balance, payments made)
            - amortizationSchedule (month-by-month EMI breakup table with principal/interest split)
            - rateChangeLetter (notification that interest rate has been revised)
            - interestCertificate (yearly certificate showing interest paid, used for tax filing)
            - closureLetter (loan fully repaid — NOC / No Dues / Closure confirmation)
            - insurancePolicy (loan protection or property insurance policy document)
            - collateralDocument (property papers, title deed, valuation report, mortgage deed)
            - restructuringAgreement (loan terms modified — moratorium, rescheduled payments)
            - unknown (if none of the above match)

            RULES:
            - The documentType value must be spelled EXACTLY as listed above (camelCase, no spaces).
            - If the document contains a loan amount, interest rate, and tenure but no specific type indicator, classify as sanctionLetter.
            - Focus on header text, subject lines, and key financial terms to decide.
            """)

        let truncated = String(ocrText.prefix(3000))
        let response = try await session.respond(
            to: "Classify this loan document. Output the documentType and a one-sentence reasoning.\n\nDOCUMENT TEXT:\n\(truncated)",
            generating: DocumentClassificationOutput.self
        )

        let docType = LoanDocumentType(rawValue: response.content.documentType) ?? .unknown
        return DocumentClassificationResult(
            documentType: docType,
            reasoning: response.content.reasoning
        )
    }

    func extractLoanCreation(ocrText: String) async throws -> LoanCreationFields {
        let session = LanguageModelSession(instructions: """
            You extract structured loan data from scanned bank documents (sanction letters, agreements, disbursement letters).

            FIELD-BY-FIELD EXTRACTION RULES:

            1. loanName: Look for "Home Loan", "Personal Loan", "Car Loan", "Housing Loan", "Vehicle Loan", \
            "Education Loan", "Gold Loan", "Loan Against Property", "Business Loan". \
            If not found, use "Loan".

            2. principalAmount: The sanctioned/approved/disbursed loan amount. \
            Look for: "Sanctioned Amount", "Loan Amount", "Facility Amount", "Principal", "Amount Sanctioned", "Disbursed Amount". \
            Return the raw number WITHOUT currency symbols or commas. Example: 5000000 not "₹50,00,000".

            3. annualInterestRatePercent: The yearly interest rate as a percentage NUMBER. \
            Look for: "Rate of Interest", "ROI", "Interest Rate", "Rate p.a.", "APR", "Annual Rate". \
            Return just the number. Example: 8.5 not "8.5%" or "8.50% p.a.".

            4. monthlyEMI: The monthly installment amount. \
            Look for: "EMI", "Monthly Installment", "Equated Monthly Installment", "Repayment Amount". \
            Return raw number without currency symbols.

            5. tenureMonths: Total loan duration in MONTHS (not years). \
            If document says "20 years", return 240. If it says "180 months", return 180. \
            Look for: "Tenure", "Period", "Repayment Period", "Loan Term", "Duration".

            6. startDate: Loan start/disbursement/sanction date in YYYY-MM-DD format. \
            Convert from any format (DD/MM/YYYY, DD-MMM-YYYY, etc.) to YYYY-MM-DD. \
            If not found, return empty string "".

            7. emiDay: Day of month when EMI is debited (1-31). \
            Look for: "EMI due date", "Debit date", "Installment date". If not found, return 0.

            8. bankName: Name of the lending institution. \
            Look in letterhead, header, or "Dear Customer" section. Return full name like "HDFC Bank", "State Bank of India".

            9. rateType: Return "floating" if rate is linked to MCLR/repo/RLLR/benchmark/variable. \
            Return "fixed" if explicitly stated as fixed. Return "" if unclear.

            10. prepaymentPenaltyPercent: Prepayment/foreclosure penalty percentage. Return 0 if not mentioned.

            11. currencyCode: ISO 4217 code. "INR" if ₹/Rs/Rupees, "USD" if $/Dollars, "EUR" if €, "GBP" if £. \
            Return "" if not determinable.

            IMPORTANT: For any field not found in the document, use the default (0 for numbers, "" for strings). \
            Never guess or hallucinate values that aren't in the text.
            """)

        let truncated = String(ocrText.prefix(4000))
        let response = try await session.respond(
            to: "Extract all loan fields from this document:\n\nDOCUMENT TEXT:\n\(truncated)",
            generating: LoanCreationFields.self
        )
        return response.content
    }

    func extractRateChange(ocrText: String) async throws -> RateChangeFields {
        let session = LanguageModelSession(instructions: """
            You extract interest rate change details from bank notification letters.

            FIELD-BY-FIELD EXTRACTION RULES:

            1. newRatePercent: The NEW/revised annual interest rate as a percentage number. \
            Look for: "Revised Rate", "New Rate of Interest", "New ROI", "Rate w.e.f.", "Current Rate". \
            Return just the number (e.g., 8.75).

            2. effectiveDate: The date the new rate takes effect, in YYYY-MM-DD format. \
            Look for: "w.e.f.", "with effect from", "effective from", "effective date", "applicable from". \
            Convert any date format to YYYY-MM-DD.

            3. previousRatePercent: The OLD/existing rate before revision, as a percentage number. \
            Look for: "Old Rate", "Previous Rate", "Existing Rate", "Earlier Rate". Return 0 if not mentioned.

            4. reason: Brief reason for the change. \
            Look for: "Repo Rate", "MCLR", "RBI", "benchmark", "policy rate". Return "" if not stated.

            5. bankName: Name of the bank from the letterhead or body.

            IMPORTANT: Return 0 for numbers and "" for strings if not found. Never guess values.
            """)

        let truncated = String(ocrText.prefix(3000))
        let response = try await session.respond(
            to: "Extract rate change details from this bank letter:\n\nDOCUMENT TEXT:\n\(truncated)",
            generating: RateChangeFields.self
        )
        return response.content
    }

    func extractStatement(ocrText: String) async throws -> LoanStatementFields {
        let session = LanguageModelSession(instructions: """
            You extract summary data from loan account statements.

            FIELD-BY-FIELD EXTRACTION RULES:

            1. outstandingBalance: The current remaining/outstanding loan balance. \
            Look for: "Outstanding Balance", "Principal Outstanding", "Balance as on", "Closing Balance", \
            "Amount Due", "Remaining Principal". Return raw number without currency symbols.

            2. statementDate: The date the statement was generated or the "as on" date, in YYYY-MM-DD format. \
            Convert any format to YYYY-MM-DD.

            3. emisPaid: Number of EMIs/installments paid so far. \
            Look for: "EMIs Paid", "Installments Paid", "No. of EMIs". Return 0 if not mentioned.

            4. totalInterestPaid: Total interest paid to date. \
            Look for: "Total Interest", "Interest Paid", "Cumulative Interest", "Interest Component". \
            Return raw number. Return 0 if not mentioned.

            5. bankName: Name of the bank from the letterhead or header.

            IMPORTANT: Return 0 for numbers and "" for strings if not found. Never guess values.
            """)

        let truncated = String(ocrText.prefix(3000))
        let response = try await session.respond(
            to: "Extract statement summary from this loan statement:\n\nDOCUMENT TEXT:\n\(truncated)",
            generating: LoanStatementFields.self
        )
        return response.content
    }
}

// MARK: - Regex-Based Fallback Extractor

/// Extracts loan details from OCR text using regex patterns.
/// Works on all devices without requiring Apple Intelligence or CoreML.
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

// MARK: - CoreML Fallback Implementation

/// Uses a downloaded CoreML model for document extraction on devices
/// without Apple Intelligence.
struct CoreMLExtractor: DocumentExtractor {
    let modelURL: URL

    func classify(ocrText: String) async throws -> DocumentClassificationResult {
        // TODO: Load CoreML model, tokenize, run prediction
        throw ExtractionError.modelNotAvailable
    }

    func extractLoanCreation(ocrText: String) async throws -> LoanCreationFields {
        throw ExtractionError.modelNotAvailable
    }

    func extractRateChange(ocrText: String) async throws -> RateChangeFields {
        throw ExtractionError.modelNotAvailable
    }

    func extractStatement(ocrText: String) async throws -> LoanStatementFields {
        throw ExtractionError.modelNotAvailable
    }
}

// MARK: - CoreML Model Manager

/// Manages downloading, compiling, and storing a fallback CoreML model
/// for devices without Apple Intelligence.
@Observable
final class CoreMLModelManager {
    static let shared = CoreMLModelManager()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(String)

        static func == (lhs: ModelState, rhs: ModelState) -> Bool {
            switch (lhs, rhs) {
            case (.notDownloaded, .notDownloaded): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.downloaded, .downloaded): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: ModelState = .notDownloaded

    private var modelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLModels", isDirectory: true)
    }

    var compiledModelURL: URL {
        modelDirectory.appendingPathComponent("LoanDocExtractor.mlmodelc")
    }

    /// Placeholder — replace with your actual CDN endpoint.
    private let remoteModelURL = URL(string: "https://models.example.com/LoanDocExtractor.mlpackage.zip")!

    private init() {
        if FileManager.default.fileExists(atPath: compiledModelURL.path) {
            state = .downloaded
        }
    }

    /// Download and compile the CoreML model.
    func downloadModel() async {
        state = .downloading(progress: 0)

        do {
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

            let (tempURL, _) = try await URLSession.shared.download(from: remoteModelURL)

            // Compile the downloaded model
            let compiledURL = try await MLModel.compileModel(at: tempURL)

            // Move to permanent location
            if FileManager.default.fileExists(atPath: compiledModelURL.path) {
                try FileManager.default.removeItem(at: compiledModelURL)
            }
            try FileManager.default.moveItem(at: compiledURL, to: compiledModelURL)

            state = .downloaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Delete the downloaded model to free disk space.
    func deleteModel() {
        try? FileManager.default.removeItem(at: compiledModelURL)
        state = .notDownloaded
    }

    /// Disk space used by the model in bytes, nil if not downloaded.
    var modelSizeOnDisk: Int64? {
        guard state == .downloaded else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: compiledModelURL.path)
        return attrs?[.size] as? Int64
    }
}

// MARK: - Extractor Factory

/// Picks the best available extraction backend.
enum ExtractorAvailability {
    case appleIntelligence
    case downloadedModel
    case regexFallback
}

enum DocumentExtractorFactory {

    /// Check which extraction backend is available (best → worst).
    static func availability() -> ExtractorAvailability {
        let model = SystemLanguageModel.default
        if case .available = model.availability {
            return .appleIntelligence
        }
        if CoreMLModelManager.shared.state == .downloaded {
            return .downloadedModel
        }
        return .regexFallback
    }

    /// Create the best available extractor. Always returns a valid extractor:
    /// Apple Intelligence > CoreML > Regex fallback.
    static func makeExtractor() -> (extractor: DocumentExtractor, source: ExtractorAvailability) {
        switch availability() {
        case .appleIntelligence:
            return (FoundationModelsExtractor(), .appleIntelligence)
        case .downloadedModel:
            return (CoreMLExtractor(modelURL: CoreMLModelManager.shared.compiledModelURL), .downloadedModel)
        case .regexFallback:
            return (RegexExtractor(), .regexFallback)
        }
    }
}

// MARK: - Errors

enum ExtractionError: LocalizedError {
    case modelNotAvailable
    case classificationFailed
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable:
            return "No document processing model is available. Enable Apple Intelligence or download the on-device model."
        case .classificationFailed:
            return "Could not determine the document type."
        case .extractionFailed(let detail):
            return "Failed to extract details: \(detail)"
        }
    }
}
