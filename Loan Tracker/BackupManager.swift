import Foundation
import CryptoKit
import SwiftData
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Backup data transfer objects

struct LoanBackupDTO: Codable {
    let id: String
    let name: String
    let principal: Double
    let annualInterestRate: Double
    let monthlyPayment: Double
    let elapsedMonths: Double
    let paidBeforeTracking: Double
    let currentOutstanding: Double
    let startDate: Date
    let tenureMonths: Int
    let emiDay: Int
    /// Optional override for the first full EMI date. nil = use default
    /// (startDate + 1 month on emiDay). Set for loans with a Pre-EMI period.
    let firstEMIDate: Date?
    let createdAt: Date
    let payments: [PaymentBackupDTO]
}

struct PaymentBackupDTO: Codable {
    let amount: Double
    let date: Date
    let note: String?
}

/// Plaintext content that gets encrypted into a backup file.
struct BackupContents: Codable {
    let version: Int      // schema version, for forward compat
    let loans: [LoanBackupDTO]
}

/// On-disk encrypted backup format.
struct EncryptedBackup: Codable {
    let fileVersion: Int  // backup file format version, not data schema
    let exportDate: Date
    let salt: String        // base64
    let nonce: String       // base64
    let ciphertext: String  // base64
    let tag: String         // base64

    static let currentFileVersion = 1
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case invalidFile
    case wrongPassphrase
    case unsupportedVersion
    case corruptedData

    var errorDescription: String? {
        switch self {
        case .invalidFile:        return "This doesn't look like a valid backup file."
        case .wrongPassphrase:    return "Wrong passphrase. The data could not be decrypted."
        case .unsupportedVersion: return "This backup was made with a newer version of the app."
        case .corruptedData:      return "The backup file is corrupted."
        }
    }
}

// MARK: - Encryption helpers

enum BackupCrypto {
    /// Derive a 32-byte key from a passphrase using SHA256 with 100k iterations.
    /// Not as strong as Argon2 or PBKDF2 with HMAC, but plenty for a personal
    /// loan backup file behind a passphrase the user actually knows.
    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var current = Data(passphrase.utf8) + salt
        for _ in 0..<100_000 {
            current = Data(SHA256.hash(data: current))
        }
        return SymmetricKey(data: current)
    }

    static func encrypt(_ plaintext: Data, passphrase: String) throws -> EncryptedBackup {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        let nonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }
        return EncryptedBackup(
            fileVersion: EncryptedBackup.currentFileVersion,
            exportDate: .now,
            salt: salt.base64EncodedString(),
            nonce: nonceData.base64EncodedString(),
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
    }

    static func decrypt(_ backup: EncryptedBackup, passphrase: String) throws -> Data {
        guard let salt = Data(base64Encoded: backup.salt),
              let nonceData = Data(base64Encoded: backup.nonce),
              let ciphertext = Data(base64Encoded: backup.ciphertext),
              let tag = Data(base64Encoded: backup.tag)
        else { throw BackupError.corruptedData }

        let key = deriveKey(passphrase: passphrase, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            // AES-GCM tag mismatch — wrong passphrase or tampered file
            throw BackupError.wrongPassphrase
        }
    }
}

// MARK: - Manager (export / import flows)

enum BackupManager {
    /// Build an encrypted backup file from the current loans.
    static func exportData(loans: [Loan], passphrase: String) throws -> Data {
        let dtos = loans.map { loan in
            LoanBackupDTO(
                id: loan.id.uuidString,
                name: loan.name,
                principal: loan.principal,
                annualInterestRate: loan.annualInterestRate,
                monthlyPayment: loan.monthlyPayment,
                elapsedMonths: loan.elapsedMonths,
                paidBeforeTracking: loan.paidBeforeTracking,
                currentOutstanding: loan.currentOutstanding,
                startDate: loan.startDate,
                tenureMonths: loan.tenureMonths,
                emiDay: loan.emiDay,
                firstEMIDate: loan.firstEMIDate,
                createdAt: loan.createdAt,
                payments: loan.payments.map {
                    PaymentBackupDTO(amount: $0.amount, date: $0.date, note: $0.note)
                }
            )
        }

        let contents = BackupContents(version: 1, loans: dtos)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(contents)

        let encrypted = try BackupCrypto.encrypt(plaintext, passphrase: passphrase)

        let outer = JSONEncoder()
        outer.dateEncodingStrategy = .iso8601
        outer.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try outer.encode(encrypted)
    }

    /// Inspect a file before restoring. Tells us how many loans without committing.
    static func previewImport(fileData: Data, passphrase: String) throws -> [LoanBackupDTO] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encrypted: EncryptedBackup
        do {
            encrypted = try decoder.decode(EncryptedBackup.self, from: fileData)
        } catch {
            throw BackupError.invalidFile
        }
        guard encrypted.fileVersion <= EncryptedBackup.currentFileVersion else {
            throw BackupError.unsupportedVersion
        }

        let plaintext = try BackupCrypto.decrypt(encrypted, passphrase: passphrase)

        let contents: BackupContents
        do {
            contents = try decoder.decode(BackupContents.self, from: plaintext)
        } catch {
            throw BackupError.corruptedData
        }
        return contents.loans
    }

    /// Wipe existing data and restore from DTOs.
    @MainActor
    static func restore(loans dtos: [LoanBackupDTO], context: ModelContext) throws {
        // 1. Delete everything currently in the store.
        try context.delete(model: Payment.self)
        try context.delete(model: Loan.self)

        // 2. Insert restored loans + their payments.
        for dto in dtos {
            let loan = Loan(
                name: dto.name,
                principal: dto.principal,
                annualInterestRate: dto.annualInterestRate,
                monthlyPayment: dto.monthlyPayment,
                elapsedMonths: dto.elapsedMonths,
                paidBeforeTracking: dto.paidBeforeTracking,
                currentOutstanding: dto.currentOutstanding,
                startDate: dto.startDate,
                tenureMonths: dto.tenureMonths,
                emiDay: dto.emiDay,
                firstEMIDate: dto.firstEMIDate
            )
            // Preserve the original id if it's a valid UUID, so widget configurations
            // pinned to specific loans keep working after restore.
            if let id = UUID(uuidString: dto.id) {
                loan.id = id
            }
            // Preserve original createdAt for stable list ordering.
            loan.createdAt = dto.createdAt

            context.insert(loan)
            for p in dto.payments {
                let payment = Payment(amount: p.amount, date: p.date, note: p.note)
                payment.loan = loan
                loan.payments.append(payment)
                context.insert(payment)
            }
        }

        try context.save()
    }
}

// MARK: - FileDocument adapter for .fileExporter

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
