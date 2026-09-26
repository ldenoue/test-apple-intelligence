import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SummaryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            youtubeLoader

            if let availabilityMessage = viewModel.availabilityMessage {
                Label(availabilityMessage, systemImage: "apple.intelligence")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            HSplitView {
                editorPanel
                    .frame(minWidth: 300)
                summaryPanel
                    .frame(minWidth: 300)
            }

            controls
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: viewModel.youtubeURL) {
            viewModel.youtubeURLDidChange()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summarize with Apple Intelligence")
                .font(.largeTitle.bold())
            Text("Your text is processed by Apple's on-device language model.")
                .foregroundStyle(.secondary)
        }
    }

    private var youtubeLoader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("YouTube transcript")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("Paste a YouTube video URL", text: $viewModel.youtubeURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.loadYouTubeTranscript() }
                    }

                Button("Load Transcript", systemImage: "captions.bubble") {
                    Task { await viewModel.loadYouTubeTranscript() }
                }
                .disabled(!viewModel.canLoadTranscript)

                if viewModel.isLoadingTranscript {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = viewModel.transcriptError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let status = viewModel.transcriptStatus {
                Label(status, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("A valid pasted URL loads automatically using the video's default caption language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.sourceText.count) characters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $viewModel.sourceText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityLabel("Text to summarize")
        }
        .padding(.trailing, 8)
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary")
                    .font(.headline)
                if viewModel.isSummarizing || viewModel.elapsedTime > 0 {
                    Text(timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.summary.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.summary, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.4))

                if viewModel.isSummarizing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(viewModel.progressMessage)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView(
                        "Summary Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if viewModel.summary.isEmpty {
                    ContentUnavailableView(
                        "No Summary Yet",
                        systemImage: "text.quote",
                        description: Text("Paste text on the left, then click Summarize.")
                    )
                } else {
                    ScrollView {
                        Text(viewModel.summary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            }
        }
        .padding(.leading, 8)
    }

    private var timeLabel: String {
        let minutes = Int(viewModel.elapsedTime) / 60
        let seconds = viewModel.elapsedTime.truncatingRemainder(dividingBy: 60)
        let duration = minutes > 0
            ? String(format: "%d:%04.1f", minutes, seconds)
            : String(format: "%.1f s", seconds)
        return viewModel.isSummarizing ? duration : "Completed in \(duration)"
    }

    private var controls: some View {
        HStack {
            Button("Clear") {
                viewModel.clear()
            }
            .disabled(viewModel.sourceText.isEmpty && viewModel.summary.isEmpty)

            Toggle("Fast mode", isOn: $viewModel.useFastMode)
                .toggleStyle(.switch)
                .help("Sample representative passages and summarize with one model request")

            Spacer()

            Button {
                Task { await viewModel.summarize() }
            } label: {
                Label("Summarize", systemImage: "apple.intelligence")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSummarize)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }
}
