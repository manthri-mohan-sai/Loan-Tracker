import Foundation

// MARK: - Bank Loan Template

/// Pre-configured loan parameters for major banks worldwide.
/// Users can pick a template when creating a loan to auto-fill rate ranges,
/// penalty info, and rate type. Updated with each app release.
struct BankLoanTemplate: Identifiable, Hashable {
    let id: String
    let bankName: String
    let country: String          // ISO 3166-1 alpha-2
    let currencyCode: String     // ISO 4217
    let loanType: LoanCategory
    let typicalRateMin: Double   // annual, as decimal (e.g. 0.085)
    let typicalRateMax: Double
    let isFloatingRate: Bool
    let prepaymentPenaltyPercent: Double
    let maxTenureMonths: Int
    let notes: String
}

enum LoanCategory: String, CaseIterable, Identifiable {
    case home = "Home"
    case car = "Car"
    case personal = "Personal"
    case education = "Education"
    case business = "Business"

    var id: String { rawValue }

    var iconKey: String {
        switch self {
        case .home: return "home"
        case .car: return "car"
        case .personal: return "person"
        case .education: return "education"
        case .business: return "business"
        }
    }
}

// MARK: - Global Bank Templates

/// Curated list of loan templates from major banks worldwide.
/// Rates are indicative as of mid-2025 and should be verified.
enum BankTemplateStore {

    static let all: [BankLoanTemplate] = india + usa + uk + europe + middleEast + southeastAsia + australia + canada + africa + latinAmerica

    // MARK: - India

    static let india: [BankLoanTemplate] = [
        // Home Loans
        BankLoanTemplate(id: "sbi-home", bankName: "SBI", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0840, typicalRateMax: 0.0915,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "No prepayment charges on floating rate (RBI directive). Linked to EBLR."),
        BankLoanTemplate(id: "hdfc-home", bankName: "HDFC Bank", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0870, typicalRateMax: 0.0945,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "No prepayment charges on floating rate. Linked to RLLR."),
        BankLoanTemplate(id: "icici-home", bankName: "ICICI Bank", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0875, typicalRateMax: 0.0960,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "No prepayment charges on floating rate. Linked to EBLR."),
        BankLoanTemplate(id: "axis-home", bankName: "Axis Bank", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0890, typicalRateMax: 0.1050,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "No prepayment charges on floating rate."),
        BankLoanTemplate(id: "kotak-home", bankName: "Kotak Mahindra", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0890, typicalRateMax: 0.0965,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 240,
            notes: "No prepayment charges on floating rate."),
        BankLoanTemplate(id: "bob-home", bankName: "Bank of Baroda", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0840, typicalRateMax: 0.1065,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "No prepayment charges on floating rate. Linked to BRLLR."),
        BankLoanTemplate(id: "pnb-home", bankName: "PNB", country: "IN", currencyCode: "INR",
            loanType: .home, typicalRateMin: 0.0840, typicalRateMax: 0.1040,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "No prepayment charges on floating rate."),

        // Personal Loans - India
        BankLoanTemplate(id: "sbi-personal", bankName: "SBI", country: "IN", currencyCode: "INR",
            loanType: .personal, typicalRateMin: 0.1100, typicalRateMax: 0.1465,
            isFloatingRate: true, prepaymentPenaltyPercent: 3, maxTenureMonths: 72,
            notes: "Prepayment penalty up to 3% of outstanding."),
        BankLoanTemplate(id: "hdfc-personal", bankName: "HDFC Bank", country: "IN", currencyCode: "INR",
            loanType: .personal, typicalRateMin: 0.1050, typicalRateMax: 0.1650,
            isFloatingRate: false, prepaymentPenaltyPercent: 4, maxTenureMonths: 60,
            notes: "Up to 4% foreclosure charges."),

        // Car Loans - India
        BankLoanTemplate(id: "sbi-car", bankName: "SBI", country: "IN", currencyCode: "INR",
            loanType: .car, typicalRateMin: 0.0870, typicalRateMax: 0.0930,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 84,
            notes: "No prepayment charges on floating rate."),
        BankLoanTemplate(id: "hdfc-car", bankName: "HDFC Bank", country: "IN", currencyCode: "INR",
            loanType: .car, typicalRateMin: 0.0875, typicalRateMax: 0.1225,
            isFloatingRate: false, prepaymentPenaltyPercent: 5, maxTenureMonths: 84,
            notes: "Foreclosure charges may apply in the first year."),

        // Education Loans - India
        BankLoanTemplate(id: "sbi-education", bankName: "SBI", country: "IN", currencyCode: "INR",
            loanType: .education, typicalRateMin: 0.0850, typicalRateMax: 0.1050,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 180,
            notes: "No prepayment penalty. Tax deduction u/s 80E on interest."),
    ]

    // MARK: - United States

    static let usa: [BankLoanTemplate] = [
        BankLoanTemplate(id: "chase-mortgage-30", bankName: "Chase", country: "US", currencyCode: "USD",
            loanType: .home, typicalRateMin: 0.0650, typicalRateMax: 0.0725,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "30-year fixed. No prepayment penalty (federal Dodd-Frank rule for QM loans)."),
        BankLoanTemplate(id: "chase-mortgage-15", bankName: "Chase", country: "US", currencyCode: "USD",
            loanType: .home, typicalRateMin: 0.0575, typicalRateMax: 0.0650,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 180,
            notes: "15-year fixed. No prepayment penalty."),
        BankLoanTemplate(id: "bofa-mortgage", bankName: "Bank of America", country: "US", currencyCode: "USD",
            loanType: .home, typicalRateMin: 0.0660, typicalRateMax: 0.0730,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "30-year fixed. No prepayment penalty."),
        BankLoanTemplate(id: "wells-mortgage", bankName: "Wells Fargo", country: "US", currencyCode: "USD",
            loanType: .home, typicalRateMin: 0.0640, typicalRateMax: 0.0720,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "30-year fixed. No prepayment penalty."),
        BankLoanTemplate(id: "chase-auto", bankName: "Chase", country: "US", currencyCode: "USD",
            loanType: .car, typicalRateMin: 0.0550, typicalRateMax: 0.0800,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 84,
            notes: "No prepayment penalty on auto loans."),
        BankLoanTemplate(id: "sofi-personal", bankName: "SoFi", country: "US", currencyCode: "USD",
            loanType: .personal, typicalRateMin: 0.0849, typicalRateMax: 0.2349,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 84,
            notes: "No origination fees, no prepayment penalty."),
        BankLoanTemplate(id: "federal-student", bankName: "Federal (Direct)", country: "US", currencyCode: "USD",
            loanType: .education, typicalRateMin: 0.0553, typicalRateMax: 0.0805,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 120,
            notes: "Federal student loans. IDR plans available. No prepayment penalty."),
    ]

    // MARK: - United Kingdom

    static let uk: [BankLoanTemplate] = [
        BankLoanTemplate(id: "barclays-mortgage", bankName: "Barclays", country: "GB", currencyCode: "GBP",
            loanType: .home, typicalRateMin: 0.0450, typicalRateMax: 0.0600,
            isFloatingRate: false, prepaymentPenaltyPercent: 3, maxTenureMonths: 420,
            notes: "Fixed-rate initial period (2-5yr), then SVR. Early repayment charges apply during fixed period."),
        BankLoanTemplate(id: "hsbc-uk-mortgage", bankName: "HSBC UK", country: "GB", currencyCode: "GBP",
            loanType: .home, typicalRateMin: 0.0440, typicalRateMax: 0.0580,
            isFloatingRate: false, prepaymentPenaltyPercent: 2, maxTenureMonths: 420,
            notes: "Early repayment charges typically 1-3% during fixed period. 10% annual overpayment usually allowed free."),
        BankLoanTemplate(id: "natwest-mortgage", bankName: "NatWest", country: "GB", currencyCode: "GBP",
            loanType: .home, typicalRateMin: 0.0450, typicalRateMax: 0.0600,
            isFloatingRate: false, prepaymentPenaltyPercent: 3, maxTenureMonths: 420,
            notes: "Tracker and fixed options. ERC during initial rate period."),
        BankLoanTemplate(id: "barclays-personal", bankName: "Barclays", country: "GB", currencyCode: "GBP",
            loanType: .personal, typicalRateMin: 0.0590, typicalRateMax: 0.1490,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 60,
            notes: "No early repayment charges on personal loans (UK CCA regulation)."),
    ]

    // MARK: - Europe (Eurozone)

    static let europe: [BankLoanTemplate] = [
        BankLoanTemplate(id: "dbank-mortgage", bankName: "Deutsche Bank", country: "DE", currencyCode: "EUR",
            loanType: .home, typicalRateMin: 0.0350, typicalRateMax: 0.0450,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "German Baufinanzierung. Sondertilgung (special repayment) of 5-10% annually typically allowed free."),
        BankLoanTemplate(id: "ing-mortgage", bankName: "ING", country: "NL", currencyCode: "EUR",
            loanType: .home, typicalRateMin: 0.0380, typicalRateMax: 0.0460,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "10-20% annual penalty-free overpayment. Interest deductible (hypotheekrenteaftrek)."),
        BankLoanTemplate(id: "bnp-mortgage", bankName: "BNP Paribas", country: "FR", currencyCode: "EUR",
            loanType: .home, typicalRateMin: 0.0340, typicalRateMax: 0.0420,
            isFloatingRate: false, prepaymentPenaltyPercent: 3, maxTenureMonths: 300,
            notes: "French law caps early repayment penalty at 3% of outstanding or 6 months' interest (whichever is lower)."),
    ]

    // MARK: - Middle East

    static let middleEast: [BankLoanTemplate] = [
        BankLoanTemplate(id: "enbd-mortgage", bankName: "Emirates NBD", country: "AE", currencyCode: "AED",
            loanType: .home, typicalRateMin: 0.0399, typicalRateMax: 0.0525,
            isFloatingRate: true, prepaymentPenaltyPercent: 1, maxTenureMonths: 300,
            notes: "UAE Central Bank caps early settlement fee at 1% of outstanding or AED 10,000."),
        BankLoanTemplate(id: "adcb-mortgage", bankName: "ADCB", country: "AE", currencyCode: "AED",
            loanType: .home, typicalRateMin: 0.0375, typicalRateMax: 0.0499,
            isFloatingRate: true, prepaymentPenaltyPercent: 1, maxTenureMonths: 300,
            notes: "Linked to EIBOR. Early settlement fee capped per UAE Central Bank."),
        BankLoanTemplate(id: "enbd-personal", bankName: "Emirates NBD", country: "AE", currencyCode: "AED",
            loanType: .personal, typicalRateMin: 0.0499, typicalRateMax: 0.0899,
            isFloatingRate: false, prepaymentPenaltyPercent: 1, maxTenureMonths: 48,
            notes: "Early settlement fee capped at 1% of outstanding."),
    ]

    // MARK: - Southeast Asia

    static let southeastAsia: [BankLoanTemplate] = [
        BankLoanTemplate(id: "dbs-sg-mortgage", bankName: "DBS", country: "SG", currencyCode: "SGD",
            loanType: .home, typicalRateMin: 0.0260, typicalRateMax: 0.0380,
            isFloatingRate: true, prepaymentPenaltyPercent: 1.5, maxTenureMonths: 360,
            notes: "Lock-in period 2-3 years. Penalty during lock-in only. Linked to SORA."),
        BankLoanTemplate(id: "maybank-mortgage", bankName: "Maybank", country: "MY", currencyCode: "MYR",
            loanType: .home, typicalRateMin: 0.0370, typicalRateMax: 0.0450,
            isFloatingRate: true, prepaymentPenaltyPercent: 3, maxTenureMonths: 420,
            notes: "Lock-in period 3-5 years. Linked to OPR. Penalty of 2-3% during lock-in."),
        BankLoanTemplate(id: "bdo-mortgage", bankName: "BDO", country: "PH", currencyCode: "PHP",
            loanType: .home, typicalRateMin: 0.0700, typicalRateMax: 0.0900,
            isFloatingRate: false, prepaymentPenaltyPercent: 3, maxTenureMonths: 240,
            notes: "Fixed rate for initial period (1-5 years), then repriced."),
    ]

    // MARK: - Australia

    static let australia: [BankLoanTemplate] = [
        BankLoanTemplate(id: "cba-mortgage", bankName: "CommBank (CBA)", country: "AU", currencyCode: "AUD",
            loanType: .home, typicalRateMin: 0.0590, typicalRateMax: 0.0680,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "Variable rate — no break fees. Extra repayments encouraged."),
        BankLoanTemplate(id: "anz-mortgage", bankName: "ANZ", country: "AU", currencyCode: "AUD",
            loanType: .home, typicalRateMin: 0.0600, typicalRateMax: 0.0690,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "Variable rate — unlimited extra repayments, no penalty."),
        BankLoanTemplate(id: "cba-fixed", bankName: "CommBank (CBA)", country: "AU", currencyCode: "AUD",
            loanType: .home, typicalRateMin: 0.0570, typicalRateMax: 0.0650,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "Fixed rate — break costs may apply for early exit during fixed period."),
    ]

    // MARK: - Canada

    static let canada: [BankLoanTemplate] = [
        BankLoanTemplate(id: "rbc-mortgage", bankName: "RBC Royal Bank", country: "CA", currencyCode: "CAD",
            loanType: .home, typicalRateMin: 0.0490, typicalRateMax: 0.0570,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 300,
            notes: "Variable rate. 10-20% annual lump sum prepayment allowed. 5-year terms typical."),
        BankLoanTemplate(id: "td-mortgage", bankName: "TD Bank", country: "CA", currencyCode: "CAD",
            loanType: .home, typicalRateMin: 0.0470, typicalRateMax: 0.0550,
            isFloatingRate: false, prepaymentPenaltyPercent: 3, maxTenureMonths: 300,
            notes: "Fixed rate. Prepayment penalty: higher of 3 months' interest or IRD. 15% annual lump sum allowed."),
    ]

    // MARK: - Africa

    static let africa: [BankLoanTemplate] = [
        BankLoanTemplate(id: "fnb-mortgage", bankName: "FNB", country: "ZA", currencyCode: "ZAR",
            loanType: .home, typicalRateMin: 0.1100, typicalRateMax: 0.1275,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 360,
            notes: "Linked to prime rate. No penalty on variable-rate home bonds per South African NCA."),
        BankLoanTemplate(id: "equity-mortgage", bankName: "Equity Bank", country: "KE", currencyCode: "KES",
            loanType: .home, typicalRateMin: 0.1300, typicalRateMax: 0.1600,
            isFloatingRate: true, prepaymentPenaltyPercent: 0, maxTenureMonths: 300,
            notes: "Linked to CBK rate. Kenya caps interest rates at CBR + 4%."),
        BankLoanTemplate(id: "gtbank-personal", bankName: "GTBank", country: "NG", currencyCode: "NGN",
            loanType: .personal, typicalRateMin: 0.1800, typicalRateMax: 0.2800,
            isFloatingRate: false, prepaymentPenaltyPercent: 2, maxTenureMonths: 48,
            notes: "Salary-backed personal loan. Rates tied to MPR."),
    ]

    // MARK: - Latin America

    static let latinAmerica: [BankLoanTemplate] = [
        BankLoanTemplate(id: "bbva-mx-mortgage", bankName: "BBVA Mexico", country: "MX", currencyCode: "MXN",
            loanType: .home, typicalRateMin: 0.0999, typicalRateMax: 0.1250,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 240,
            notes: "Fixed rate. No prepayment penalty under Mexican law (Ley de Transparencia)."),
        BankLoanTemplate(id: "itau-mortgage", bankName: "Itaú", country: "BR", currencyCode: "BRL",
            loanType: .home, typicalRateMin: 0.1049, typicalRateMax: 0.1199,
            isFloatingRate: false, prepaymentPenaltyPercent: 0, maxTenureMonths: 420,
            notes: "Fixed rate + TR index. No prepayment penalty per Brazilian consumer code."),
    ]

    // MARK: - Filtering

    /// Filter templates by country, loan type, or both.
    static func filtered(country: String? = nil, loanType: LoanCategory? = nil) -> [BankLoanTemplate] {
        all.filter { t in
            (country == nil || t.country == country) &&
            (loanType == nil || t.loanType == loanType)
        }
    }

    /// All unique countries available in templates.
    static var countries: [(code: String, name: String)] {
        let codes = Set(all.map(\.country)).sorted()
        let locale = Locale.current
        return codes.compactMap { code in
            guard let name = locale.localizedString(forRegionCode: code) else { return nil }
            return (code: code, name: name)
        }
    }
}
