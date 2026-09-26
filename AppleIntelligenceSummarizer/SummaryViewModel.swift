import Combine
import Foundation
import FoundationModels
import NaturalLanguage

@MainActor
final class SummaryViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var summary = ""
    @Published var errorMessage: String?
    @Published var isSummarizing = false
    @Published var progressMessage = "Creating summary…"
    @Published var elapsedTime: TimeInterval = 0
    @Published var useFastMode = true
    @Published var youtubeURL = ""
    @Published var isLoadingTranscript = false
    @Published var transcriptStatus: String?
    @Published var transcriptError: String?

    private let model = SystemLanguageModel.default
    private let transcriptService = YouTubeTranscriptService()
    private var timerTask: Task<Void, Never>?
    private var youtubeDebounceTask: Task<Void, Never>?
    private var lastLoadedYouTubeURL: String?

    var canSummarize: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSummarizing
            && model.isAvailable
    }

    var canLoadTranscript: Bool {
        YouTubeTranscriptService.videoID(from: youtubeURL) != nil && !isLoadingTranscript
    }

    var availabilityMessage: String? {
        switch model.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "Apple Intelligence isn't supported on this Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings to summarize text."
        case .unavailable(.modelNotReady):
            "The Apple Intelligence model is still downloading or isn't ready yet."
        case .unavailable:
            "Apple Intelligence is currently unavailable."
        }
    }

    func summarize() async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.isAvailable, !isSummarizing else { return }

        let startTime = Date()
        isSummarizing = true
        elapsedTime = 0
        progressMessage = "Creating summary…"
        errorMessage = nil
        summary = ""
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.elapsedTime = Date().timeIntervalSince(startTime)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            timerTask?.cancel()
            timerTask = nil
            elapsedTime = Date().timeIntervalSince(startTime)
            isSummarizing = false
        }

        do {
            if useFastMode {
                progressMessage = "Selecting representative passages…"
                let sample = representativeText(from: text)
                progressMessage = "Creating fast summary…"
                summary = try await summarize(sample, maximumWords: 100)
                return
            }

            let textChunks = chunks(from: text)

            if textChunks.count == 1 {
                summary = try await summarize(textChunks[0], maximumWords: 100)
                return
            }

            var partialSummaries: [String] = []
            for (index, chunk) in textChunks.enumerated() {
                progressMessage = "Summarizing part \(index + 1) of \(textChunks.count)…"
                partialSummaries.append(try await summarize(chunk))
            }

            while partialSummaries.count > 1 {
                let groups = chunks(from: partialSummaries.joined(separator: "\n\n"))
                var combinedSummaries: [String] = []

                for (index, group) in groups.enumerated() {
                    progressMessage = groups.count == 1
                        ? "Combining summaries…"
                        : "Combining summaries \(index + 1) of \(groups.count)…"
                    combinedSummaries.append(
                        try await summarize(
                            group,
                            maximumWords: groups.count == 1 ? 100 : nil
                        )
                    )
                }

                partialSummaries = combinedSummaries
            }

            summary = partialSummaries[0]
        } catch {
            errorMessage = "Couldn't create a summary: \(error.localizedDescription)"
        }
    }

    func clear() {
        youtubeDebounceTask?.cancel()
        youtubeURL = ""
        sourceText = ""
        summary = ""
        errorMessage = nil
        elapsedTime = 0
        transcriptStatus = nil
        transcriptError = nil
        lastLoadedYouTubeURL = nil
    }

    func youtubeURLDidChange() {
        youtubeDebounceTask?.cancel()
        transcriptStatus = nil
        transcriptError = nil

        let candidate = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeTranscriptService.videoID(from: candidate) != nil,
              candidate != lastLoadedYouTubeURL else { return }

        youtubeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.loadYouTubeTranscript()
        }
    }

    func loadYouTubeTranscript() async {
        let url = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeTranscriptService.videoID(from: url) != nil, !isLoadingTranscript else {
            if !url.isEmpty, YouTubeTranscriptService.videoID(from: url) == nil {
                transcriptError = "Enter a valid YouTube video URL."
            }
            return
        }

        isLoadingTranscript = true
        transcriptError = nil
        transcriptStatus = "Loading the default caption track…"
        defer { isLoadingTranscript = false }

        do {
            let transcript = try await transcriptService.transcript(from: url)
            guard !Task.isCancelled else { return }
            sourceText = transcript.text
            summary = ""
            errorMessage = nil
            elapsedTime = 0
            lastLoadedYouTubeURL = url
            transcriptStatus = "Loaded \(transcript.languageCode) captions (\(transcript.text.count) characters). Summarizing…"
            isLoadingTranscript = false
            await summarize()
            transcriptStatus = summary.isEmpty
                ? "Loaded \(transcript.languageCode) captions (\(transcript.text.count) characters)."
                : "Loaded \(transcript.languageCode) captions and created a summary."
        } catch is CancellationError {
            return
        } catch {
            transcriptStatus = nil
            transcriptError = error.localizedDescription
        }
    }

    private func summarize(_ text: String, maximumWords: Int? = nil) async throws -> String {
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            options: GenerationOptions(maximumResponseTokens: 160)
        ) {
            if let maximumWords {
                "Summarize in one short paragraph of no more than \(maximumWords) words: \(text)"
            } else {
                "Summarize in a short paragraph: \(text)"
            }
        }
        return response.content
    }

    /// Keeps each request comfortably below the 4,096-token context window.
    /// ASCII text costs one unit per character; other scripts use a more
    /// conservative four units because they commonly require more tokens.
    private func chunks(from text: String, unitLimit: Int = 11_000) -> [String] {
        var result: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            var cursor = start
            var units = 0
            var lastNaturalBreak: String.Index?
            var unitsAtLastBreak = 0

            while cursor < text.endIndex {
                let character = text[cursor]
                let isASCII = character.unicodeScalars.allSatisfy { $0.isASCII }
                let cost = isASCII ? 1 : 4
                guard units + cost <= unitLimit else { break }

                units += cost
                cursor = text.index(after: cursor)

                if character == "\n" || ".!?。！？".contains(character) {
                    lastNaturalBreak = cursor
                    unitsAtLastBreak = units
                }
            }

            var end = cursor
            if cursor < text.endIndex,
               let naturalBreak = lastNaturalBreak,
               unitsAtLastBreak >= unitLimit / 2 {
                end = naturalBreak
            }

            if end == start {
                end = text.index(after: start)
            }

            let chunk = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                result.append(chunk)
            }

            start = end
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
        }

        return result
    }

    /// Samples sentences at regular intervals so Fast mode covers the whole
    /// document while fitting in a single model request.
    private func representativeText(from text: String, unitLimit: Int = 10_500) -> String {
        guard estimatedUnits(in: text) > unitLimit else { return text }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        guard !sentences.isEmpty else {
            return chunks(from: text, unitLimit: unitLimit).first ?? text
        }

        let totalUnits = sentences.reduce(0) { $0 + estimatedUnits(in: $1) }
        let sentenceStride = max(1, Double(totalUnits) / Double(unitLimit))
        var selected: [String] = []
        var selectedUnits = 0
        var position = 0.0

        while Int(position) < sentences.count {
            let sentence = sentences[Int(position)]
            let cost = estimatedUnits(in: sentence) + 2
            if selectedUnits + cost <= unitLimit {
                selected.append(sentence)
                selectedUnits += cost
            }
            position += sentenceStride
        }

        if let last = sentences.last,
           selected.last != last,
           selectedUnits + estimatedUnits(in: last) + 2 <= unitLimit {
            selected.append(last)
        }

        if selected.isEmpty {
            return chunks(from: text, unitLimit: unitLimit).first ?? text
        }

        return selected.joined(separator: "\n\n")
    }

    private func estimatedUnits(in text: String) -> Int {
        text.reduce(into: 0) { total, character in
            let isASCII = character.unicodeScalars.allSatisfy { $0.isASCII }
            total += isASCII ? 1 : 4
        }
    }
}
