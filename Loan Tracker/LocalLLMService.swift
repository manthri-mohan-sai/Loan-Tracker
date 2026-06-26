import Foundation
import llama

// MARK: - Local LLM Service (llama.cpp / GGUF)
//
// Runs GGUF models on-device using llama.cpp — no CoreML, no internet
// connection required after the model file is downloaded.
//
// ── Setup ────────────────────────────────────────────────────────────────────
// 1. In Xcode: File → Add Package Dependencies
//    https://github.com/ggml-org/llama.cpp
//    (add the "llama" library target to "Loan Tracker")
//
// 2. Recommended model (user downloads via Settings → Download Model):
//    Qwen2.5-0.5B-Instruct-Q4_K_M.gguf  (~350 MB)
//    https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF
// ─────────────────────────────────────────────────────────────────────────────

actor LocalLLMService {

    // MARK: - Shared Instance

    static let shared = LocalLLMService()

    // MARK: - State

    private var model:   OpaquePointer?   // llama_model *
    private var context: OpaquePointer?   // llama_context *

    var isLoaded: Bool { model != nil && context != nil }

    // MARK: - Load

    func load(from url: URL) throws {
        // One-time backend init (safe to call repeatedly)
        llama_backend_init()

        // Load the GGUF weights
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 0   // llama.cpp uses Metal internally on Apple hardware

        guard let loadedModel = llama_load_model_from_file(url.path, modelParams) else {
            throw LLMError.modelNotLoaded
        }

        // Create inference context
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx      = 1024   // token context window
        ctxParams.n_batch    = 512    // prompt decode batch size
        ctxParams.n_threads  = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        ctxParams.flash_attn = true   // faster attention on supported hardware

        guard let ctx = llama_new_context_with_model(loadedModel, ctxParams) else {
            llama_free_model(loadedModel)
            throw LLMError.modelNotLoaded
        }

        self.model   = loadedModel
        self.context = ctx
    }

    // MARK: - Unload

    func unload() {
        if let ctx = context { llama_free(ctx) }
        if let mdl = model   { llama_free_model(mdl) }
        context = nil
        model   = nil
    }

    // MARK: - Generate

    /// Runs the Qwen instruct chat template then generates up to maxNewTokens.
    /// Returns the raw generated string (JSON in our case).
    func generate(
        system:        String,
        user:          String,
        maxNewTokens:  Int   = 300,
        temperature:   Float = 0.0
    ) async throws -> String {
        guard let model, let context else { throw LLMError.modelNotLoaded }

        // Qwen chat template
        let prompt = "<|im_start|>system\n\(system)<|im_end|>\n" +
                     "<|im_start|>user\n\(user)<|im_end|>\n" +
                     "<|im_start|>assistant\n"

        // ── Tokenize ─────────────────────────────────────────────────────
        var promptTokens = [llama_token](repeating: 0, count: 2048)
        let nRaw = llama_tokenize(
            model, prompt, Int32(prompt.utf8.count),
            &promptTokens, Int32(promptTokens.count),
            true,   // add BOS
            true    // parse special tokens (<|im_start|> etc.)
        )
        guard nRaw > 0 else { throw LLMError.emptyPrompt }

        // Truncate to leave headroom for output (context = 1024)
        let maxPromptTokens = 724
        promptTokens = Array(promptTokens.prefix(Int(min(nRaw, Int32(maxPromptTokens)))))

        // ── Prefill ───────────────────────────────────────────────────────
        llama_kv_cache_clear(context)

        let prefillResult = promptTokens.withUnsafeMutableBufferPointer { ptr in
            llama_decode(context, llama_batch_get_one(ptr.baseAddress!, Int32(ptr.count)))
        }
        guard prefillResult == 0 else { throw LLMError.unexpectedOutputShape }

        // ── Sampler setup ─────────────────────────────────────────────────
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw LLMError.modelNotLoaded
        }
        defer { llama_sampler_free(sampler) }

        if temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }

        // ── Decode loop ───────────────────────────────────────────────────
        var output = ""

        for _ in 0..<maxNewTokens {
            var newToken = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, newToken)

            if llama_token_is_eog(model, newToken) { break }

            // Token ID → text piece
            var piece = [CChar](repeating: 0, count: 256)
            let pieceLen = llama_token_to_piece(model, newToken, &piece, 256, 0, false)
            if pieceLen > 0 { output += String(cString: piece) }

            // Feed token back into context
            let stepResult = withUnsafeMutablePointer(to: &newToken) { ptr in
                llama_decode(context, llama_batch_get_one(ptr, 1))
            }
            if stepResult != 0 { break }
        }

        return output
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
            return "Model decoding failed — check context size or GGUF format."
        case .jsonParseFailed(let raw):
            return "Could not parse JSON from model output: \(raw.prefix(120))"
        }
    }
}

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
