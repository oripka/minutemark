import AppKit
import Foundation
import SwiftUI

struct TranscriptDocument: Identifiable, Hashable {
    let url: URL
    let title: String
    let date: Date
    let contents: String

    var id: URL { url }

    var displayDate: String {
        date.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .hour()
                .minute()
        )
    }
}

@MainActor
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var documents: [TranscriptDocument] = []
    @Published var selectedURL: URL?
    @Published private(set) var errorMessage: String?

    var selectedDocument: TranscriptDocument? {
        documents.first { $0.url == selectedURL }
    }

    func reload(from directory: URL) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            documents = urls
                .filter { $0.pathExtension.lowercased() == "md" }
                .compactMap(loadDocument)
                .sorted { $0.date > $1.date }
            errorMessage = nil

            if selectedURL == nil || selectedDocument == nil {
                selectedURL = documents.first?.url
            }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain &&
                  error.code == NSFileReadNoSuchFileError {
            documents = []
            selectedURL = nil
            errorMessage = nil
        } catch {
            documents = []
            selectedURL = nil
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ document: TranscriptDocument) throws {
        let diagnosticsURL = document.url
            .deletingPathExtension()
            .appendingPathExtension("diagnostics.log")

        try FileManager.default.trashItem(
            at: document.url,
            resultingItemURL: nil
        )

        if FileManager.default.fileExists(atPath: diagnosticsURL.path) {
            try FileManager.default.trashItem(
                at: diagnosticsURL,
                resultingItemURL: nil
            )
        }

        documents.removeAll { $0.id == document.id }
        if selectedURL == document.url {
            selectedURL = documents.first?.url
        }
    }

    private func loadDocument(at url: URL) -> TranscriptDocument? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let title = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        let date = dateFromFilename(url.lastPathComponent)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
            ?? .distantPast

        return TranscriptDocument(
            url: url,
            title: title,
            date: date,
            contents: contents
        )
    }

    private func dateFromFilename(_ filename: String) -> Date? {
        guard filename.count >= 17 else { return nil }
        let prefix = String(filename.prefix(17))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.date(from: prefix)
    }
}

struct TranscriptLibraryView: View {
    @ObservedObject var appModel: AppModel
    @StateObject private var library = TranscriptLibrary()
    @State private var searchText = ""
    @State private var pendingDeletion: TranscriptDocument?
    @State private var deletionError: String?

    private var visibleDocuments: [TranscriptDocument] {
        guard !searchText.isEmpty else { return library.documents }
        return library.documents.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.contents.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if visibleDocuments.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No transcripts yet" : "No matches",
                        systemImage: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Completed transcripts will appear here."
                                : "Try a different title or phrase."
                        )
                    )
                } else {
                    List(visibleDocuments, selection: $library.selectedURL) { document in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(document.displayDate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(document.url)
                        .contextMenu {
                            Button("Open in TextEdit") {
                                appModel.openTranscriptInTextEdit(document.url)
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [document.url]
                                )
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) {
                                pendingDeletion = document
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transcripts")
            .searchable(text: $searchText, prompt: "Search transcripts")
            .toolbar {
                Button {
                    library.reload(from: appModel.outputDirectory)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh transcripts")
            }
        } detail: {
            if let document = library.selectedDocument {
                TranscriptPreview(document: document)
                    .toolbar {
                        Button {
                            appModel.openTranscriptInTextEdit(document.url)
                        } label: {
                            Label("Open in TextEdit", systemImage: "square.and.pencil")
                        }

                        Button(role: .destructive) {
                            pendingDeletion = document
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        .help("Move transcript to Trash")
                    }
            } else {
                ContentUnavailableView(
                    "Select a transcript",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a note from the list to preview it.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            library.reload(from: appModel.outputDirectory)
        }
        .onChange(of: appModel.outputDirectory) {
            library.reload(from: appModel.outputDirectory)
        }
        .confirmationDialog(
            "Move this transcript to Trash?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let document = pendingDeletion else { return }
                do {
                    try library.moveToTrash(document)
                } catch {
                    deletionError = error.localizedDescription
                    library.reload(from: appModel.outputDirectory)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let document = pendingDeletion {
                Text(
                    "“\(document.title)” and its diagnostics log can be recovered from macOS Trash."
                )
            }
        }
        .alert(
            "Couldn’t Move Transcript",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK") {
                deletionError = nil
            }
        } message: {
            Text(deletionError ?? "An unknown error occurred.")
        }
    }
}

private struct TranscriptPreview: View {
    let document: TranscriptDocument

    var body: some View {
        ScrollView {
            MarkdownDocumentView(markdown: document.contents)
                .frame(maxWidth: 720, alignment: .topLeading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(document.title)
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case quote(String)
    case divider
    case code(String)

}

private struct MarkdownDocumentView: View {
    let blocks: [MarkdownBlock]

    init(markdown: String) {
        blocks = MarkdownDocumentParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .fontWeight(level <= 2 ? .semibold : .medium)
                .padding(.top, level == 1 ? 4 : 10)
                .padding(.bottom, level == 1 ? 4 : 0)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(4)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                Text(inlineMarkdown(text))
                    .font(.body)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)

        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineSpacing(3)
            }
            .padding(.vertical, 3)

        case .divider:
            Divider()
                .padding(.vertical, 6)

        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title2
        case 3: .headline
        default: .subheadline
        }
    }
}

private enum MarkdownDocumentParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if isInCodeBlock {
                    flushCode()
                } else {
                    flushParagraph()
                }
                isInCodeBlock.toggle()
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if line == "---" || line == "***" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }

            paragraphLines.append(line)
        }

        flushParagraph()
        flushCode()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty,
              hashes.count <= 6,
              line.dropFirst(hashes.count).first == " "
        else {
            return nil
        }

        return (
            hashes.count,
            String(line.dropFirst(hashes.count + 1))
        )
    }
}
