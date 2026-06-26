import Foundation
import CoreML

// MARK: - Local LLM Service
//
// Non-stateful inference: feeds the full growing token sequence to the
// model at every decode step and reads logits at the last position.
//
// Compatible with iOS 16+ — no makeState() / MLState required.
//
// Model contract (produced by CoreML-Conversion/convert_qwen.py):
//   Input  "input_ids"  shape [1, seq_len]         dtype int32
//   Output "logits"     shape [1, seq_len, vocab]   dtype float16

actor LocalLLMService {

    // MARK: - Shared Instance

    static let shared = LocalLLMService()

    // MARK: - State

    private var model: MLModel?
    private var tokenizer: QwenTokenizer?

    var isLoaded: Bool { model != nil && tokenizer != nil }

    // MARK: - Load / Unload

    func load(from url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: config)
        tokenizer = try QwenTokenizer.loadFromBundle()
    }

    func unload() {
        model = nil
        tokenizer = nil
    }

    // MARK: - Generate

    /// Run inference with a system + user prompt. Returns the raw model output string.
    ///
    /// - Parameters:
    ///   - system: System instruction (kept short — model is tiny).
    ///   - user: Document text to process.
    ///   - maxNewTokens: Hard cap on generated tokens (default 300).
    ///   - temperature: 0 = greedy/deterministic, best for structured JSON output.
    func generate(
        system: String,
        user: String,
        maxNewTokens: Int = 300,
        temperature: Float = 0.0
    ) async throws -> String {
        guard let model, let tokenizer else {
            throw LLMError.modelNotLoaded
        }

        let promptIds = tokenizer.applyChatTemplate(system: system, user: user)
        guard !promptIds.isEmpty else { throw LLMError.emptyPrompt }

        // Truncate prompt to keep total tokens within the model's MAX_SEQ_LEN (1024).
        // Keep the suffix so the assistant turn and recent content are always present.
        let maxPromptTokens = 724   // 1024 - 300 output tokens
        var tokenIds: [Int] = promptIds.count <= maxPromptTokens
            ? promptIds
            : Array(promptIds.suffix(maxPromptTokens))

        var generatedIds: [Int] = []

        for _ in 0..<maxNewTokens {
            let seqLen = tokenIds.count

            // Build [1, seqLen] int32 input
            let inputArray = try MLMultiArray(
                shape: [1, NSNumber(value: seqLen)],
                dataType: .int32
            )
            for (i, id) in tokenIds.enumerated() {
                inputArray[i] = NSNumber(value: id)
            }

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputArray)
            ])
            let output = try model.prediction(from: features)

            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                throw LLMError.unexpectedOutputShape
            }

            // Sample next token from logits at the last sequence position
            let nextId = temperature == 0
                ? argmaxLastPosition(logits, seqLen: seqLen)
                : sampleLastPosition(logits, seqLen: seqLen, temperature: temperature)

            if nextId == QwenTokenizer.eosTokenId || nextId == QwenTokenizer.imEndTokenId {
                break
            }

            generatedIds.append(nextId)
            tokenIds.append(nextId)
        }

        return tokenizer.decode(generatedIds)
    }

    // MARK: - Logit Helpers

    /// Greedy argmax over logits at position [0, seqLen-1, :].
    /// Uses direct pointer access for performance over 152K vocab entries.
    private func argmaxLastPosition(_ logits: MLMultiArray, seqLen: Int) -> Int {
        let vocabSize  = logits.shape[2].intValue
        let lastOffset = (seqLen - 1) * vocabSize
        var bestIdx = 0
        var bestVal: Float = -.infinity

        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<vocabSize {
                let v = ptr[lastOffset + i]
                if v > bestVal { bestVal = v; bestIdx = i }
            }
        case .float16:
            let ptr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<vocabSize {
                let v = Float(Float16(bitPattern: ptr[lastOffset + i]))
                if v > bestVal { bestVal = v; bestIdx = i }
            }
        default:
            // Fallback: slow but correct
            for i in 0..<vocabSize {
                let v = logits[[0, NSNumber(value: seqLen - 1), NSNumber(value: i)]].floatValue
                if v > bestVal { bestVal = v; bestIdx = i }
            }
        }
        return bestIdx
    }

    /// Temperature sampling over logits at position [0, seqLen-1, :].
    private func sampleLastPosition(
        _ logits: MLMultiArray,
        seqLen: Int,
        temperature: Float
    ) -> Int {
        let vocabSize  = logits.shape[2].intValue
        let lastOffset = (seqLen - 1) * vocabSize

        var vals = [Float](repeating: 0, count: vocabSize)
        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<vocabSize { vals[i] = ptr[lastOffset + i] / temperature }
        case .float16:
            let ptr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<vocabSize {
                vals[i] = Float(Float16(bitPattern: ptr[lastOffset + i])) / temperature
            }
        default:
            for i in 0..<vocabSize {
                vals[i] = logits[[0, NSNumber(value: seqLen - 1), NSNumber(value: i)]].floatValue / temperature
            }
        }

        // Numerically stable softmax
        let maxVal = vals.max() ?? 0
        var exps   = vals.map { expf($0 - maxVal) }
        let expSum = exps.reduce(0, +)
        guard expSum > 0 else { return argmaxLastPosition(logits, seqLen: seqLen) }
        exps = exps.map { $0 / expSum }

        let r = Float.random(in: 0..<1)
        var cumulative: Float = 0
        for (i, p) in exps.enumerated() {
            cumulative += p
            if r < cumulative { return i }
        }
        return vocabSize - 1
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotLoaded
    case emptyPrompt
    case unexpectedOutputShape
    case jsonParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Local LLM model is not loaded. Download it from Settings."
        case .emptyPrompt:
            return "Tokenizer produced an empty prompt."
        case .unexpectedOutputShape:
            return "Model output did not contain expected 'logits' feature."
        case .jsonParseFailed(let raw):
            return "Could not parse JSON from model output: \(raw.prefix(120))"
        }
    }
}
