import Foundation
import SwiftLlama

// MARK: - LLM Errors

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

// MARK: - LocalLLMService
//
// Runs GGUF models on-device using SwiftLlama (llama.cpp wrapper).
// No internet connection required after the model file is downloaded.
//
// ── Setup ────────────────────────────────────────────────────────────────────
// 1. In Xcode: File → Add Package Dependencies
//    https://github.com/ShenghaiWang/SwiftLlama.git  (branch: main)
//    Add SwiftLlama library to Loan Tracker target.
//
// 2. Recommended model (~350 MB, user downloads via Settings → Download Model):
//    Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
//    https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF
// ─────────────────────────────────────────────────────────────────────────────

actor LocalLLMService {
    
    // MARK: - Shared Instance
    
    static let shared = LocalLLMService()
    
    // MARK: - State
    
    private var swiftLlama: SwiftLlama?
    private var currentModelURL: URL?
    private(set) var isLoaded = false
    
    private init() {}
    
    // MARK: - Load
    
    /// Load a GGUF model from disk. Safe to call multiple times —
    /// skips reload if the same model URL is already loaded.
    func load(from url: URL) async throws {
        if isLoaded, currentModelURL == url { return }
        if isLoaded { await unload() }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LLMError.modelNotLoaded
        }
        
        swiftLlama = try SwiftLlama(
            modelPath: url.path,
            modelConfiguration: .init(
                nCTX: 2048,
                temperature: 0.7,       // greedy — best for JSON extraction
                maxTokenCount: 512,
                stopTokens: []
                
            )
        )
        currentModelURL = url
        isLoaded = true
    }
    
    // MARK: - Unload
    
    func unload() async {
        swiftLlama = nil
        currentModelURL = nil
        isLoaded = false
    }
    
    // MARK: - Generate
    
    /// Generate a response given a system prompt and user message.
    /// Uses Qwen2.5 ChatML format.
    ///
    /// - Parameters:
    ///   - system: System instruction — keep concise, model is small.
    ///   - user: Document text or query to process.
    ///   - maxNewTokens: Hard cap on generated tokens (default 300).
    /// - Returns: Raw model output string (JSON in our case).
    func generate(
        system: String,
        user: String,
        maxNewTokens: Int = 300
    ) async throws -> String {
        guard let swiftLlama, isLoaded else {
            throw LLMError.modelNotLoaded
        }
        
        let truncatedUser = String(user.prefix(800))
        
        // Alpaca uses plain text — no special tokens needed
        // Embed system into the instruction directly
        let fullInstruction = """
            SYSTEM: \(system)
            
            USER: \(truncatedUser)
            
            ASSISTANT:
            """
        
        let prompt = Prompt(
            type: .alpaca,
            systemPrompt: "",
            userMessage: fullInstruction
        )
        
        var output = ""
        var tokenCount = 0
        
        print("🤖 Starting generation with prompt length: \(fullInstruction.count)")
        
        for try await token in await swiftLlama.start(for: prompt, sessionSupport: false) {
            print("🔤 Token \(tokenCount): '\(token)'")
            output += token
            tokenCount += 1
            if tokenCount > maxNewTokens { break }
        }
        
        print("🤖 Total tokens: \(tokenCount)")
        print("🤖 Output: \(output)")
        
        guard !output.isEmpty else {
            throw LLMError.emptyPrompt
        }
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
