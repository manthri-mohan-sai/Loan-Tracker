import Foundation

// MARK: - Qwen BPE Tokenizer
//
// Loads vocab.json + merges.txt bundled in the app target.
// Compatible with Qwen2.5 and Qwen3 (they share the same tokenizer).
//
// Required bundle resources:
//   qwen_vocab.json   — from https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main/vocab.json
//   qwen_merges.txt   — from https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main/merges.txt

struct QwenTokenizer {

    // MARK: - Special Token IDs (fixed across Qwen2.5 / Qwen3)
    static let bosTokenId:     Int = 151643  // <|endoftext|>
    static let eosTokenId:     Int = 151643  // <|endoftext|>
    static let imStartTokenId: Int = 151644  // <|im_start|>
    static let imEndTokenId:   Int = 151645  // <|im_end|>

    private let encoder: [String: Int]   // token piece → id
    private let decoder: [Int: String]   // id → token piece
    private let merges: [(String, String)]
    private let byteEncoder: [UInt8: String]
    private let byteDecoder: [String: UInt8]

    // MARK: - Init

    init(vocabURL: URL, mergesURL: URL) throws {
        // Load vocab.json
        let vocabData = try Data(contentsOf: vocabURL)
        guard let rawVocab = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw TokenizerError.invalidVocab
        }
        self.encoder = rawVocab
        self.decoder = Dictionary(uniqueKeysWithValues: rawVocab.map { ($1, $0) })

        // Load merges.txt — skip the version comment line
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        self.merges = mergesText
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }

        // Build byte ↔ unicode mappings (same as GPT-2 / tiktoken)
        var be: [UInt8: String] = [:]
        var bd: [String: UInt8] = [:]
        // Printable ASCII (! → ~) and extended Latin map to themselves
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        for (b, c) in zip(bs, cs) {
            let char = String(UnicodeScalar(c)!)
            be[UInt8(b)] = char
            bd[char] = UInt8(b)
        }
        self.byteEncoder = be
        self.byteDecoder = bd
    }

    // MARK: - Load from App Bundle

    static func loadFromBundle() throws -> QwenTokenizer {
        guard
            let vocabURL  = Bundle.main.url(forResource: "qwen_vocab",  withExtension: "json"),
            let mergesURL = Bundle.main.url(forResource: "qwen_merges", withExtension: "txt")
        else {
            throw TokenizerError.bundleFilesMissing
        }
        return try QwenTokenizer(vocabURL: vocabURL, mergesURL: mergesURL)
    }

    // MARK: - Encode

    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids: [Int] = []

        // GPT-2 style: split on whitespace boundaries then BPE each piece
        let words = gpt2Pretokenize(text)
        for word in words {
            let byteStr = word.utf8.map { byteEncoder[$0] ?? "?" }.joined()
            let tokens = bpeMerge(byteStr)
            ids += tokens.compactMap { encoder[$0] }
        }
        return ids
    }

    // MARK: - Decode

    func decode(_ ids: [Int]) -> String {
        let pieces = ids.compactMap { decoder[$0] }
        let joined = pieces.joined()
        // Convert byte-level chars back to UTF-8 bytes then to String
        let bytes = joined.unicodeScalars.compactMap { scalar -> UInt8? in
            byteDecoder[String(scalar)]
        }
        return String(bytes: bytes, encoding: .utf8) ?? joined
    }

    // MARK: - Chat Template (Qwen instruct format)
    //
    // Produces token IDs for:
    //   <|im_start|>system\n{system}<|im_end|>\n
    //   <|im_start|>user\n{user}<|im_end|>\n
    //   <|im_start|>assistant\n

    func applyChatTemplate(system: String, user: String) -> [Int] {
        var ids: [Int] = []

        ids.append(QwenTokenizer.imStartTokenId)
        ids += encode("system\n\(system)")
        ids.append(QwenTokenizer.imEndTokenId)
        ids += encode("\n")

        ids.append(QwenTokenizer.imStartTokenId)
        ids += encode("user\n\(user)")
        ids.append(QwenTokenizer.imEndTokenId)
        ids += encode("\n")

        ids.append(QwenTokenizer.imStartTokenId)
        ids += encode("assistant\n")

        return ids
    }

    // MARK: - GPT-2 Pre-tokenizer

    // Splits text into words the same way GPT-2 does:
    // contiguous letters, contraction suffixes, punctuation, digits, whitespace+word
    private func gpt2Pretokenize(_ text: String) -> [String] {
        // Pattern matches: contractions, letters, numbers, other chars, leading space + word
        let pattern = #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [text]
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)
        return matches.map { nsText.substring(with: $0.range) }
    }

    // MARK: - BPE Merge

    private func bpeMerge(_ word: String) -> [String] {
        guard word.count > 1 else { return [word] }

        var symbols = word.map { String($0) }

        // Build a fast lookup: merge pair → rank
        let mergeRanks: [(String, String, Int)] = merges.enumerated().map { ($1.0, $1.1, $0) }

        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIdx = -1

            for i in 0..<(symbols.count - 1) {
                let pair = (symbols[i], symbols[i + 1])
                if let rank = mergeRanks.first(where: { $0.0 == pair.0 && $0.1 == pair.1 })?.2 {
                    if rank < bestRank {
                        bestRank = rank
                        bestIdx = i
                    }
                }
            }

            guard bestIdx >= 0 else { break }

            // Merge the best pair
            let merged = symbols[bestIdx] + symbols[bestIdx + 1]
            symbols.remove(at: bestIdx)
            symbols.remove(at: bestIdx)
            symbols.insert(merged, at: bestIdx)
        }

        return symbols
    }

    // MARK: - Errors

    enum TokenizerError: LocalizedError {
        case invalidVocab
        case bundleFilesMissing

        var errorDescription: String? {
            switch self {
            case .invalidVocab:
                return "qwen_vocab.json is not a valid [String: Int] dictionary."
            case .bundleFilesMissing:
                return "qwen_vocab.json or qwen_merges.txt not found in app bundle. " +
                       "Download from https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct and add to Xcode target."
            }
        }
    }
}
