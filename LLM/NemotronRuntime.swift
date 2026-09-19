import Core
import Foundation
@preconcurrency import llama
import Telemetry

/// NVIDIA Nemotron 3 Nano 4B (Q4_K_M GGUF) running on llama.cpp (+ Metal on device).
///
/// - Runs on its own serial dispatch queue (custom actor executor) so multi-second decode calls
///   never block Swift's cooperative thread pool.
/// - Evaluates the static prompt prefix once and snapshots the sequence state (attention KV cache
///   + Mamba-2 recurrent state); every turn restores the snapshot and evaluates only the suffix.
/// - Decodes greedily under a GBNF grammar (deterministic, schema-constrained output).
/// - Optional jump-forward: text the grammar forces (JSON keys, punctuation, the tail of an enum
///   value) is evaluated in one batch instead of token by token.
/// - Optional prompt-lookup speculation: inside a string value, the continuation of the user's own
///   words is drafted and verified in the same decode call; only tokens equal to the model's
///   greedy choice are kept (llama.cpp's recurrent-state snapshots roll back the rest), so the
///   output is unchanged and only the number of GPU passes drops.
public actor NemotronRuntime: LanguageModel {
    public nonisolated let modelIdentifier: String

    private let modelURL: URL
    private let config: LLMConfig
    private let stateCacheDirectory: URL?
    private let jumpForward: OutputAutomaton?
    private let logger: PrivacySafeLogger
    private let queue = DispatchSerialQueue(label: "voiceagent.llm.inference", qos: .userInitiated)

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var handles: LlamaHandles?
    private var vocabSize = 0
    /// Maximum speculative draft length (0 = speculation off); bounded by the context's
    /// recurrent-state rollback depth.
    private var draftLimit = 0
    /// The prefix currently restored into the context.
    private var snapshot: PrefixSnapshot?
    /// Recently evaluated prefixes, newest last. V2 decodes under more than one contract (a turn,
    /// memory extraction, an agent step); keeping a couple of prefix states in memory means
    /// switching between them is a memcpy rather than a re-evaluation, so background work can never
    /// cost the next user turn its warm prefix.
    private var prefixCache: [PrefixSnapshot] = []
    private var candidates: [llama_token_data] = []

    private var context: OpaquePointer? { handles?.context }
    private var vocab: OpaquePointer? { handles?.vocab }
    public private(set) var loadMilliseconds: Double = 0

    private struct PrefixSnapshot {
        let prefixHash: Int
        let tokenCount: Int
        let state: [UInt8]
    }

    /// The start of the next turn's suffix, evaluated on top of the prefix while the user speaks.
    private struct PrimedSuffix {
        let text: String
        let tokens: [llama_token]
        let position: Int
    }

    private var primed: PrimedSuffix?

    /// - Parameters:
    ///   - stateCacheDirectory: when set, the evaluated prefix state is persisted on disk keyed by a
    ///     hash of (model, prompt prefix, context size) and reloaded on the next launch.
    ///   - jumpForward: automaton of the output language used to emit grammar-forced text in
    ///     batches (nil disables jump-forward even if the config enables it).
    public init(
        modelURL: URL,
        config: LLMConfig = LLMConfig(),
        modelIdentifier: String = "nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF@1260a77/Q4_K_M",
        stateCacheDirectory: URL? = nil,
        jumpForward: OutputAutomaton? = .agentOutput,
        logger: PrivacySafeLogger = .shared
    ) {
        self.modelURL = modelURL
        self.config = config
        self.modelIdentifier = modelIdentifier
        self.stateCacheDirectory = stateCacheDirectory
        self.jumpForward = jumpForward
        self.logger = logger
    }

    // MARK: - Lifecycle

    public var isLoaded: Bool { context != nil }

    public func load() throws {
        guard context == nil else { return }
        LlamaBackend.initialize()
        let watch = Stopwatch()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(Self.effectiveGPULayers(config.gpuLayers))
        modelParams.load_mode = config.useMemoryMap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE
        guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParams) else {
            logger.log(.error(domain: "llm", code: "model_load_failed"))
            throw LLMRuntimeError.modelLoadFailed
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(config.contextLength)
        contextParams.n_batch = UInt32(config.batchSize)
        contextParams.n_ubatch = UInt32(config.batchSize)
        contextParams.n_seq_max = 1
        // Nemotron-H keeps Mamba-2 state that cannot be truncated after the fact; llama.cpp keeps
        // one snapshot per trailing token so rejected draft tokens can be rolled back.
        let needsSnapshots = llama_model_is_recurrent(loadedModel) || llama_model_is_hybrid(loadedModel)
        let requestedDrafts = max(0, config.speculativeDraftTokens)
        contextParams.n_rs_seq = needsSnapshots ? UInt32(requestedDrafts) : 0
        let threads = Self.threadCounts(requested: config.threads)
        contextParams.n_threads = Int32(threads.generation)
        contextParams.n_threads_batch = Int32(threads.batch)
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        contextParams.no_perf = true
        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            logger.log(.error(domain: "llm", code: "context_init_failed"))
            throw LLMRuntimeError.contextInitFailed
        }
        let loadedHandles = LlamaHandles(
            model: loadedModel,
            context: loadedContext,
            batch: llama_batch_init(Int32(config.batchSize), 0, 1)
        )
        handles = loadedHandles
        draftLimit = needsSnapshots ? Int(llama_n_rs_seq(loadedContext)) : requestedDrafts
        vocabSize = Int(llama_vocab_n_tokens(loadedHandles.vocab))
        candidates = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: vocabSize)
        loadMilliseconds = watch.elapsedMilliseconds
        logger.log(.modelLifecycle(model: "nemotron", phase: "loaded", milliseconds: Int(loadMilliseconds)))
    }

    /// Frees all native memory (e.g. on a memory warning). The next request reloads.
    public func unload() {
        handles = nil
        snapshot = nil
        prefixCache.removeAll()
        primed = nil
        logger.log(.modelLifecycle(model: "nemotron", phase: "unloaded", milliseconds: nil))
    }

    public func prepare(cacheablePrefix: String) async throws {
        try load()
        try ensurePrefix(cacheablePrefix)
    }

    /// Evaluates the turn context ahead of the utterance (called at speech onset). Never loads
    /// the model: priming only helps a runtime that is already warm.
    public func prime(cacheablePrefix: String, suffixHead: String) async {
        guard context != nil, !suffixHead.isEmpty else { return }
        if let primed, primed.text == suffixHead { return }
        do {
            try ensurePrefix(cacheablePrefix)
            guard let snapshot else { return }
            primed = nil
            try restore(snapshot)
            var position = snapshot.tokenCount
            let tokens = tokenize(suffixHead, addSpecial: false)
            try evaluate(tokens, startingAt: &position)
            if let context { llama_synchronize(context) }
            primed = PrimedSuffix(text: suffixHead, tokens: tokens, position: position)
        } catch {
            primed = nil
        }
    }

    // MARK: - Generation

    public nonisolated func generate(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request) { event in continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: runs a request to completion and returns the full text plus stats.
    public func complete(_ request: LLMRequest) async throws -> (text: String, stats: LLMGenerationStats) {
        var text = ""
        var stats = LLMGenerationStats()
        try run(request) { event in
            switch event {
            case let .text(delta): text += delta
            case let .completed(final): stats = final
            }
        }
        return (text, stats)
    }

    private func run(_ request: LLMRequest, emit: (LLMStreamEvent) -> Void) throws {
        try load()
        let total = Stopwatch()
        var stats = LLMGenerationStats()
        try ensurePrefix(request.cacheablePrefix)
        guard let context, let snapshot else { throw LLMRuntimeError.contextInitFailed }

        stats.cachedPrefixTokens = snapshot.tokenCount
        let suffixTokens = tokenize(request.suffix, addSpecial: false)
        guard snapshot.tokenCount + suffixTokens.count + request.maxOutputTokens < config.contextLength else {
            throw LLMRuntimeError.contextOverflow
        }
        // Continue from the primed turn context when this suffix starts with exactly those tokens;
        // otherwise restore the post-prefix state and evaluate the whole suffix.
        var position: Int
        var pendingSuffix: [llama_token]
        var evaluated: [llama_token] // everything after the cached prefix, to rebuild the state if a rollback is refused
        if let primed, request.suffix.hasPrefix(primed.text), suffixTokens.starts(with: primed.tokens) {
            position = primed.position
            pendingSuffix = Array(suffixTokens[primed.tokens.count...])
            evaluated = primed.tokens
            stats.primedTokens = primed.tokens.count
        } else {
            try restore(snapshot)
            position = snapshot.tokenCount
            pendingSuffix = suffixTokens
            evaluated = []
        }
        primed = nil

        let grammar = try GrammarSampler(vocab: vocab, grammar: request.grammar)
        var decoder = UTF8StreamDecoder()
        var tracker = JSONCompletionTracker()
        var output = ""
        let cursor = config.jumpForwardDecoding ? jumpForward?.makeCursor() : nil
        let drafter = draftLimit > 0
            ? PromptLookupDrafter(sources: request.draftSources.isEmpty ? [request.suffix] : request.draftSources)
            : nil
        func append(_ text: String) {
            guard !text.isEmpty else { return }
            output += text
            tracker.consume(text)
            emit(.text(text))
        }

        /// Jump-forward: accepts (and emits) the text the grammar forces next. Every forced token is
        /// still checked by the grammar sampler. Returns the tokens, which still need evaluating.
        func acceptForcedText() -> [llama_token] {
            guard let cursor, decoder.isEmpty, cursor.advance(to: output) else { return [] }
            let forced = cursor.forcedContinuation()
            guard !forced.isEmpty else { return [] }
            var accepted: [llama_token] = []
            for token in tokenize(forced, addSpecial: false) {
                guard grammar.allows(token) else { break }
                grammar.accept(token)
                accepted.append(token)
            }
            stats.forcedTokens += accepted.count
            for token in accepted { append(decoder.push(piece(for: token))) }
            return accepted
        }

        func decode(_ tokens: [llama_token], outputsFrom firstOutput: Int) throws {
            try evaluate(tokens, startingAt: &position, outputsFrom: firstOutput, stats: &stats)
            evaluated += tokens
        }

        /// Drops the last `count` evaluated tokens from the model state.
        func discardLast(_ count: Int) throws {
            evaluated.removeLast(count)
            if llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(position - count), -1) {
                position -= count
                return
            }
            // Only reachable if a rollback exceeds the snapshot depth: rebuild exactly (slow).
            logger.log(.error(domain: "llm", code: "draft_rollback_rebuilt"))
            try restore(snapshot)
            position = snapshot.tokenCount
            try evaluate(evaluated, startingAt: &position, outputsFrom: evaluated.count - 1, stats: &stats)
        }

        // The (rest of the) prompt suffix and the opening every reply shares (`{"type":"`) in one
        // decode call.
        let promptWatch = Stopwatch()
        let opening = acceptForcedText()
        try decode(pendingSuffix + opening, outputsFrom: pendingSuffix.count + opening.count - 1)
        stats.promptTokens = suffixTokens.count
        stats.promptEvalMilliseconds = promptWatch.elapsedMilliseconds

        var logitsIndex: Int32 = -1 // batch index whose logits predict the next token
        var chosenNext: llama_token? // already chosen by the model while verifying a draft
        var forcedNext = false // the grammar forces text before anything needs sampling
        var firstToken = true

        while stats.sampledTokens + stats.forcedTokens < request.maxOutputTokens {
            try Task.checkCancellation()
            var batch: [llama_token] = []
            if !forcedNext {
                let token: llama_token
                if let chosen = chosenNext {
                    token = chosen
                    chosenNext = nil
                } else {
                    let samplingWatch = Stopwatch()
                    token = sampleGreedy(grammar: grammar, outputIndex: logitsIndex, stats: &stats)
                    stats.samplingMilliseconds += samplingWatch.elapsedMilliseconds
                }
                if firstToken {
                    stats.timeToFirstTokenMilliseconds = total.elapsedMilliseconds
                    firstToken = false
                }
                if llama_vocab_is_eog(vocab, token) {
                    stats.stoppedReason = "eog"
                    break
                }
                grammar.accept(token)
                stats.sampledTokens += 1
                append(decoder.push(piece(for: token)))
                if tracker.isComplete {
                    stats.stoppedReason = "json_complete"
                    break
                }
                batch.append(token)
            }
            forcedNext = false
            // Forced text goes into the SAME decode call as the sampled token.
            batch += acceptForcedText()
            if tracker.isComplete {
                // The grammar forced the rest of the object: nothing left to decode.
                stats.stoppedReason = "json_complete"
                break
            }
            if batch.isEmpty { continue } // nothing new to evaluate: sample from the same logits

            // Speculation: append a guess copied from the request; one pass scores every position.
            // Drafts only fill the call up to the small-batch size that costs about one token.
            let budget = min(request.maxOutputTokens - stats.sampledTokens - stats.forcedTokens - 1,
                             config.speculativeMaxBatchTokens - batch.count)
            let draft: [llama_token]
            if let drafter, decoder.isEmpty, budget > 0, let text = drafter.continuation(after: output) {
                draft = draftTokens(for: text, grammar: grammar, limit: min(draftLimit, budget))
            } else {
                draft = []
            }
            try decode(batch + draft, outputsFrom: batch.count - 1)
            logitsIndex = draft.isEmpty ? -1 : Int32(batch.count - 1)
            guard !draft.isEmpty else { continue }

            // Keep drafted tokens while each equals the model's own grammar-constrained greedy
            // choice at its position; the first disagreement becomes the next token.
            stats.draftTokens += draft.count
            var accepted = 0
            for token in draft {
                let samplingWatch = Stopwatch()
                let choice = sampleGreedy(grammar: grammar, outputIndex: logitsIndex, stats: &stats)
                stats.samplingMilliseconds += samplingWatch.elapsedMilliseconds
                guard choice == token else {
                    chosenNext = choice
                    break
                }
                grammar.accept(token)
                stats.sampledTokens += 1
                append(decoder.push(piece(for: token)))
                accepted += 1
                logitsIndex += 1
                if tracker.isComplete { break }
                if let cursor, decoder.isEmpty, cursor.advance(to: output), !cursor.forcedContinuation().isEmpty {
                    forcedNext = true
                    break
                }
            }
            stats.acceptedDraftTokens += accepted
            if accepted < draft.count { try discardLast(draft.count - accepted) }
            if tracker.isComplete {
                stats.stoppedReason = "json_complete"
                break
            }
        }
        if stats.stoppedReason == "unknown" { stats.stoppedReason = "max_tokens" }
        append(decoder.flush())
        stats.totalMilliseconds = total.elapsedMilliseconds
        emit(.completed(stats))
    }

    /// Tokenizes a draft and keeps the prefix the grammar would allow (checked on a copy of the
    /// grammar; the real one only advances for tokens the model confirms).
    private func draftTokens(for text: String, grammar: GrammarSampler, limit: Int) -> [llama_token] {
        guard limit > 0 else { return [] }
        let tokens = tokenize(text, addSpecial: false).prefix(limit)
        guard let probe = grammar.copy() else { return Array(tokens) }
        var result: [llama_token] = []
        for token in tokens {
            guard probe.allows(token) else { break }
            probe.accept(token)
            result.append(token)
        }
        return result
    }

    private func restore(_ snapshot: PrefixSnapshot) throws {
        guard let context else { throw LLMRuntimeError.contextInitFailed }
        llama_memory_clear(llama_get_memory(context), true)
        let restored = snapshot.state.withUnsafeBufferPointer { buffer in
            llama_state_seq_set_data(context, buffer.baseAddress, buffer.count, 0)
        }
        guard restored > 0 else { throw LLMRuntimeError.stateRestoreFailed }
    }

    // MARK: - Profiling (benchmark only)

    /// Times one decode call per batch size after the cached prefix (median of `repetitions`),
    /// with logits for the last token only or for every token (draft verification). Restores the
    /// prefix state before each call so every measurement starts from the same point.
    public func profileBatchSizes(_ sizes: [Int], allLogits: Bool, repetitions: Int = 3, cacheablePrefix: String) throws -> [Int: Double] {
        try load()
        try ensurePrefix(cacheablePrefix)
        guard let snapshot else { throw LLMRuntimeError.contextInitFailed }
        primed = nil
        let filler = tokenize(" the quick brown fox jumps over the lazy dog and runs back home again", addSpecial: false)
        var result: [Int: Double] = [:]
        for size in sizes where size > 0 && size <= config.batchSize {
            var samples: [Double] = []
            for _ in 0..<repetitions {
                try restore(snapshot)
                var position = snapshot.tokenCount
                let tokens = (0..<size).map { filler[$0 % filler.count] }
                var stats = LLMGenerationStats()
                try evaluate(tokens, startingAt: &position, outputsFrom: allLogits ? 0 : size - 1, stats: &stats)
                samples.append(stats.decodeMilliseconds)
            }
            result[size] = samples.sorted()[samples.count / 2]
        }
        return result
    }

    // MARK: - Prefix cache

    private func ensurePrefix(_ prefix: String) throws {
        guard let context else { throw LLMRuntimeError.contextInitFailed }
        var hasher = FNV1a64(); hasher.combine(prefix); hasher.combine(String(config.contextLength)); let hash = Int(truncatingIfNeeded: hasher.value)
        if let snapshot, snapshot.prefixHash == hash { return }
        primed = nil

        // Already evaluated under another contract: restore it instead of paying for it again.
        if let cached = prefixCache.first(where: { $0.prefixHash == hash }) {
            try restore(cached)
            snapshot = cached
            promote(cached)
            logger.log(.modelLifecycle(model: "nemotron", phase: "prefix_switched", milliseconds: nil))
            return
        }

        let tokens = tokenize(prefix, addSpecial: true)
        guard tokens.count + 256 < config.contextLength else { throw LLMRuntimeError.contextOverflow }
        let cacheFile = stateCacheDirectory.map { $0.appendingPathComponent(Self.cacheFileName(prefix: prefix, identifier: modelIdentifier, contextLength: config.contextLength)) }

        llama_memory_clear(llama_get_memory(context), true)
        if let cacheFile, FileManager.default.fileExists(atPath: cacheFile.path), loadStateFile(cacheFile, expectedTokens: tokens) {
            logger.log(.modelLifecycle(model: "nemotron", phase: "prefix_state_loaded", milliseconds: nil))
        } else {
            let watch = Stopwatch()
            var position = 0
            try evaluate(tokens, startingAt: &position)
            logger.log(.modelLifecycle(model: "nemotron", phase: "prefix_evaluated", milliseconds: Int(watch.elapsedMilliseconds)))
            if let cacheFile {
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = tokens.withUnsafeBufferPointer { buffer in
                    llama_state_seq_save_file(context, cacheFile.path, 0, buffer.baseAddress, buffer.count)
                }
            }
        }
        let size = llama_state_seq_get_size(context, 0)
        var state = [UInt8](repeating: 0, count: size)
        let written = state.withUnsafeMutableBufferPointer { buffer in
            llama_state_seq_get_data(context, buffer.baseAddress, size, 0)
        }
        guard written == size else { throw LLMRuntimeError.stateSnapshotFailed }
        let evaluated = PrefixSnapshot(prefixHash: hash, tokenCount: tokens.count, state: state)
        snapshot = evaluated
        promote(evaluated)
    }

    /// Keeps `snapshot` at the end of a small MRU list. Two slots is the working set: the turn
    /// contract and whatever background contract is running beside it.
    private func promote(_ entry: PrefixSnapshot) {
        prefixCache.removeAll { $0.prefixHash == entry.prefixHash }
        prefixCache.append(entry)
        if prefixCache.count > Self.prefixCacheSlots { prefixCache.removeFirst(prefixCache.count - Self.prefixCacheSlots) }
    }

    private static let prefixCacheSlots = 2

    private func loadStateFile(_ url: URL, expectedTokens: [llama_token]) -> Bool {
        guard let context else { return false }
        var loaded = [llama_token](repeating: 0, count: expectedTokens.count + 16)
        var count = 0
        let bytes = loaded.withUnsafeMutableBufferPointer { buffer in
            llama_state_seq_load_file(context, url.path, 0, buffer.baseAddress, buffer.count, &count)
        }
        guard bytes > 0, count == expectedTokens.count, Array(loaded.prefix(count)) == expectedTokens else {
            llama_memory_clear(llama_get_memory(context), true)
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    static func cacheFileName(prefix: String, identifier: String, contextLength: Int) -> String {
        var hasher = FNV1a64()
        hasher.combine(identifier)
        hasher.combine(prefix)
        hasher.combine(String(contextLength))
        hasher.combine(LlamaBackend.buildTag)
        return "prefix-\(String(hasher.value, radix: 16)).llamastate"
    }

    // MARK: - llama.cpp helpers

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var capacity = Int(byteCount) + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        var count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(capacity), addSpecial, true)
        if count < 0 {
            capacity = Int(-count)
            tokens = [llama_token](repeating: 0, count: capacity)
            count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(capacity), addSpecial, true)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, length))).map { UInt8(bitPattern: $0) }
    }

    /// Evaluates tokens and records decode time (including GPU completion) in `stats`.
    private func evaluate(
        _ tokens: [llama_token], startingAt position: inout Int, outputsFrom firstOutput: Int, stats: inout LLMGenerationStats
    ) throws {
        let watch = Stopwatch()
        try evaluate(tokens, startingAt: &position, outputsFrom: firstOutput)
        if let context { llama_synchronize(context) }
        let elapsed = watch.elapsedMilliseconds
        stats.decodeMilliseconds += elapsed
        stats.decodeCalls += 1
        stats.decodeCallTokens.append(tokens.count)
        stats.decodeCallMilliseconds.append(elapsed)
    }

    /// Evaluates tokens in `batchSize` chunks. Tokens at index `firstOutput` and later produce
    /// logits (default: only the last token); callers that need several outputs keep the whole
    /// call within one chunk, so batch indices stay valid for `llama_get_logits_ith`.
    private func evaluate(_ tokens: [llama_token], startingAt position: inout Int, outputsFrom firstOutput: Int? = nil) throws {
        let firstOutput = firstOutput ?? tokens.count - 1
        guard let handles else { throw LLMRuntimeError.contextInitFailed }
        let context = handles.context
        var batch = handles.batch
        var index = 0
        while index < tokens.count {
            try Task.checkCancellation()
            let chunk = min(config.batchSize, tokens.count - index)
            batch.n_tokens = Int32(chunk)
            for offset in 0..<chunk {
                batch.token[offset] = tokens[index + offset]
                batch.pos[offset] = llama_pos(position + offset)
                batch.n_seq_id[offset] = 1
                batch.seq_id[offset]![0] = 0
                batch.logits[offset] = index + offset >= firstOutput ? 1 : 0
            }
            let status = llama_decode(context, batch)
            guard status == 0 else {
                logger.log(.error(domain: "llm", code: "decode_failed"))
                throw LLMRuntimeError.decodeFailed(Int(status))
            }
            position += chunk
            index += chunk
        }
    }

    /// Greedy decoding under the grammar.
    ///
    /// 1. The argmax token is checked alone (almost always allowed).
    /// 2. Otherwise the candidates within `logitWindow` of the best logit are checked in descending
    ///    order, one token at a time — cheap single-token grammar checks instead of pushing all
    ///    131K vocabulary entries through the grammar.
    /// 3. Only if none of those is allowed is the whole vocabulary constrained (slow path).
    /// The chosen token is identical to constraining the full vocabulary and taking the argmax.
    private func sampleGreedy(grammar: GrammarSampler, outputIndex: Int32, stats: inout LLMGenerationStats) -> llama_token {
        guard let logits = llama_get_logits_ith(context, outputIndex) else { return llama_vocab_eos(vocab) }
        var best = 0
        var bestLogit = -Float.infinity
        for index in 0..<vocabSize where logits[index] > bestLogit {
            bestLogit = logits[index]
            best = index
        }
        if grammar.allows(llama_token(best), logit: bestLogit) { return llama_token(best) }

        let threshold = bestLogit - Self.logitWindow
        var shortlist: [(logit: Float, token: Int32)] = []
        shortlist.reserveCapacity(512)
        for index in 0..<vocabSize where logits[index] >= threshold && index != best {
            shortlist.append((logits[index], Int32(index)))
        }
        shortlist.sort { $0.logit > $1.logit }
        for candidate in shortlist.prefix(Self.shortlistLimit) where grammar.allows(candidate.token, logit: candidate.logit) {
            return candidate.token
        }

        stats.grammarFallbacks += 1
        for index in 0..<vocabSize {
            candidates[index] = llama_token_data(id: llama_token(index), logit: logits[index], p: 0)
        }
        return candidates.withUnsafeMutableBufferPointer { buffer in
            var array = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            grammar.apply(&array)
            var chosen = llama_vocab_eos(vocab)
            var chosenLogit = -Float.infinity
            for index in 0..<buffer.count where buffer[index].logit > chosenLogit {
                chosenLogit = buffer[index].logit
                chosen = buffer[index].id
            }
            return chosen
        }
    }

    /// Candidates this far below the best logit (probability ratio e^-14) are only considered on
    /// the slow path.
    static let logitWindow: Float = 14
    static let shortlistLimit = 2_048

    // MARK: - Platform defaults

    static func effectiveGPULayers(_ requested: Int) -> Int {
        #if targetEnvironment(simulator) || arch(x86_64)
        return 0 // No usable Metal backend for ggml in the simulator or on Intel GPUs.
        #else
        return requested
        #endif
    }

    static func threadCounts(requested: Int?) -> (generation: Int, batch: Int) {
        if let requested { return (requested, requested) }
        let active = ProcessInfo.processInfo.activeProcessorCount
        #if os(iOS)
        let performance = max(2, min(4, active - 2))
        return (performance, performance)
        #else
        var physical: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.physicalcpu", &physical, &size, nil, 0)
        let cores = max(1, Int(physical))
        return (cores, max(cores, active))
        #endif
    }
}

public enum LLMRuntimeError: Error, Equatable, Sendable {
    case modelLoadFailed
    case contextInitFailed
    case grammarInitFailed
    case decodeFailed(Int)
    case contextOverflow
    case stateSnapshotFailed
    case stateRestoreFailed
}

/// Owns the llama.cpp model/context/batch. Only ever touched from `NemotronRuntime`'s serial
/// executor, which is what makes the `@unchecked Sendable` sound; freed when the runtime releases it.
final class LlamaHandles: @unchecked Sendable {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer?
    let batch: llama_batch

    init(model: OpaquePointer, context: OpaquePointer, batch: llama_batch) {
        self.model = model
        self.context = context
        self.batch = batch
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }
}

/// One-time llama.cpp backend initialization with log output silenced (llama.cpp logs prompt
/// fragments at debug level; nothing from the runtime reaches the unified log).
public enum LlamaBackend {
    static let buildTag = "llama.cpp-b11046"

    private static let initialized: Bool = {
        llama_log_set({ level, text, _ in
            // Diagnostics only (benchmark mode); prompts are never logged at WARN/ERROR/INFO level
            // by llama.cpp, but the file is written only when explicitly enabled.
            guard let text, let handle = LlamaBackend.diagnosticsHandle else { return }
            handle.write(Data(String(cString: text).utf8))
        }, nil)
        llama_backend_init()
        return true
    }()

    /// Set only by the developer benchmark to capture llama.cpp's backend/graph diagnostics.
    nonisolated(unsafe) static var diagnosticsHandle: FileHandle?

    /// Writes llama.cpp's own log (Metal init, graph splits, perf) to `url`. Developer use only.
    public static func enableDiagnostics(to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        diagnosticsHandle = try? FileHandle(forWritingTo: url)
    }

    static func initialize() {
        _ = initialized
    }
}

/// Wraps a llama.cpp grammar sampler (not a chain) so single-token checks stay cheap.
final class GrammarSampler {
    private let sampler: UnsafeMutablePointer<llama_sampler>?

    init(vocab: OpaquePointer?, grammar: String?) throws {
        if let grammar {
            guard let created = llama_sampler_init_grammar(vocab, grammar, "root") else {
                throw LLMRuntimeError.grammarInitFailed
            }
            sampler = created
        } else {
            sampler = nil
        }
    }

    private init(owning sampler: UnsafeMutablePointer<llama_sampler>) {
        self.sampler = sampler
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
    }

    /// An independent copy in the same parse state (nil when there is no grammar).
    func copy() -> GrammarSampler? {
        guard let sampler, let copied = llama_sampler_clone(sampler) else { return nil }
        return GrammarSampler(owning: copied)
    }

    func allows(_ token: llama_token, logit: Float = 0) -> Bool {
        guard let sampler else { return true }
        var data = llama_token_data(id: token, logit: logit, p: 0)
        return withUnsafeMutablePointer(to: &data) { pointer in
            var array = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(sampler, &array)
            return pointer.pointee.logit.isFinite
        }
    }

    func apply(_ array: inout llama_token_data_array) {
        guard let sampler else { return }
        llama_sampler_apply(sampler, &array)
    }

    func accept(_ token: llama_token) {
        guard let sampler else { return }
        llama_sampler_accept(sampler, token)
    }
}

/// Reassembles UTF-8 text from token pieces that may split multi-byte characters.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func push(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        var validLength = pending.count
        // Trim an incomplete trailing sequence (at most 3 bytes).
        for back in 1...min(3, pending.count) {
            let byte = pending[pending.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // continuation byte
            let needed: Int
            if byte & 0b1000_0000 == 0 { needed = 1 }
            else if byte & 0b1110_0000 == 0b1100_0000 { needed = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { needed = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { needed = 4 }
            else { needed = 1 }
            if needed > back { validLength = pending.count - back }
            break
        }
        let text = String(decoding: pending.prefix(validLength), as: UTF8.self)
        pending.removeFirst(validLength)
        return text
    }

    mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Tracks whether a streamed JSON value has closed (outside strings, brace depth back to zero).
struct JSONCompletionTracker {
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var started = false
    private(set) var isComplete = false

    mutating func consume(_ text: String) {
        for character in text.unicodeScalars where !isComplete {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[":
                depth += 1
                started = true
            case "}", "]":
                depth -= 1
                if started, depth == 0 { isComplete = true }
            default: break
            }
        }
    }
}

/// Deterministic 64-bit FNV-1a (Swift's `hashValue` is randomly seeded per process).
struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0xFF
        value = value &* 0x0000_0100_0000_01B3
    }
}
