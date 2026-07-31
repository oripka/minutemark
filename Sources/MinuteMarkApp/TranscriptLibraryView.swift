import AppKit
import Darwin
import Foundation
import MinuteMarkCore
import SwiftUI

struct TranscriptDocument: Identifiable, Hashable {
    let url: URL
    var title: String
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

private final class TranscriptDirectoryMonitor: ObservableObject {
    @Published private(set) var revision = 0

    private var source: DispatchSourceFileSystemObject?

    func watch(_ directory: URL) {
        stop()

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.revision &+= 1
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}

@MainActor
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var documents: [TranscriptDocument] = []
    @Published var selectedURLs: Set<URL> = []
    @Published private(set) var errorMessage: String?

    var selectedDocument: TranscriptDocument? {
        guard selectedURLs.count == 1, let url = selectedURLs.first else {
            return nil
        }
        return documents.first { $0.url == url }
    }

    var selectedDocuments: [TranscriptDocument] {
        documents.filter { selectedURLs.contains($0.url) }
    }

    func previewTitle(_ title: String, for url: URL) {
        guard let index = documents.firstIndex(where: { $0.url == url }) else {
            return
        }
        let visibleTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[index].title = visibleTitle.isEmpty ? "Untitled" : title
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

            selectedURLs.formIntersection(documents.map(\.url))
            if selectedURLs.isEmpty, let firstURL = documents.first?.url {
                selectedURLs = [firstURL]
            }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain &&
                  error.code == NSFileReadNoSuchFileError {
            documents = []
            selectedURLs = []
            errorMessage = nil
        } catch {
            documents = []
            selectedURLs = []
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ targets: [TranscriptDocument]) throws {
        for document in targets {
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
            selectedURLs.remove(document.url)
        }

        if selectedURLs.isEmpty, let firstURL = documents.first?.url {
            selectedURLs = [firstURL]
        }
    }

    @discardableResult
    func rename(
        _ document: TranscriptDocument,
        to requestedTitle: String,
        in directory: URL
    ) throws -> URL {
        let title = TranscriptFormatter.normalizedTitle(requestedTitle)
        var lines = document.contents.components(separatedBy: .newlines)
        if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[headingIndex] = "# \(title)"
        } else {
            lines.insert(contentsOf: ["# \(title)", ""], at: 0)
        }
        let updatedContents = lines.joined(separator: "\n")

        let desiredName = TranscriptFormatter.filename(
            title: title,
            for: document.date
        )
        let destination = availableDestination(
            directory.appendingPathComponent(desiredName),
            currentURL: document.url
        )

        try Data(updatedContents.utf8).write(
            to: document.url,
            options: .atomic
        )

        let oldDiagnosticsURL = document.url
            .deletingPathExtension()
            .appendingPathExtension("diagnostics.log")
        let newDiagnosticsURL = destination
            .deletingPathExtension()
            .appendingPathExtension("diagnostics.log")

        if destination != document.url {
            try FileManager.default.moveItem(
                at: document.url,
                to: destination
            )
            if FileManager.default.fileExists(atPath: oldDiagnosticsURL.path) {
                try FileManager.default.moveItem(
                    at: oldDiagnosticsURL,
                    to: newDiagnosticsURL
                )
            }
        }

        reload(from: directory)
        selectedURLs = [destination]
        return destination
    }

    private func availableDestination(
        _ desiredURL: URL,
        currentURL: URL
    ) -> URL {
        let fileManager = FileManager.default
        guard desiredURL != currentURL else { return desiredURL }

        let base = desiredURL.deletingPathExtension().lastPathComponent
        let directory = desiredURL.deletingLastPathComponent()
        var candidate = desiredURL
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) ||
              fileManager.fileExists(
                atPath: candidate
                    .deletingPathExtension()
                    .appendingPathExtension("diagnostics.log")
                    .path
              ) {
            candidate = directory
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension("md")
            suffix += 1
        }
        return candidate
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
    @StateObject private var directoryMonitor = TranscriptDirectoryMonitor()
    @State private var searchText = ""
    @State private var pendingDeletion: [TranscriptDocument] = []
    @State private var isDeletionConfirmationPresented = false
    @State private var pendingRename: TranscriptDocument?
    @State private var operationError: String?

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
                    List(visibleDocuments, selection: $library.selectedURLs) { document in
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
                        .onTapGesture(count: 2) {
                            guard !isActive(document) else { return }
                            pendingRename = document
                        }
                        .contextMenu {
                            Button("Rename…") {
                                pendingRename = document
                            }
                            .disabled(isActive(document))
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
                                requestDeletion([document])
                            }
                            .disabled(isActive(document))
                        }
                    }
                    .onDeleteCommand {
                        let documents = library.selectedDocuments
                        guard !documents.isEmpty,
                              !documents.contains(where: isActive)
                        else {
                            return
                        }
                        requestDeletion(documents)
                    }
                }
            }
            .navigationTitle("Transcripts")
            .searchable(text: $searchText, prompt: "Search transcripts")
            .navigationSplitViewColumnWidth(
                min: 320,
                ideal: 380,
                max: 480
            )
        } detail: {
            if library.selectedDocuments.count > 1 {
                MultiSelectionView(count: library.selectedDocuments.count)
                    .toolbar {
                        Button(role: .destructive) {
                            requestDeletion(library.selectedDocuments)
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        .help("Move selected transcripts to Trash")
                        .disabled(library.selectedDocuments.contains(where: isActive))
                    }
            } else if let document = library.selectedDocument {
                TranscriptPreview(
                    document: document,
                    isRenameDisabled: isActive(document),
                    onTitleChange: { draftTitle in
                        library.previewTitle(draftTitle, for: document.url)
                    },
                    onRename: { newTitle in
                        do {
                            try library.rename(
                                document,
                                to: newTitle,
                                in: appModel.outputDirectory
                            )
                            return true
                        } catch {
                            operationError = error.localizedDescription
                            library.reload(from: appModel.outputDirectory)
                            return false
                        }
                    }
                )
                    .toolbar {
                        Button {
                            pendingRename = document
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .help("Rename transcript")
                        .disabled(isActive(document))

                        Button {
                            appModel.openTranscriptInTextEdit(document.url)
                        } label: {
                            Label("Open in TextEdit", systemImage: "arrow.up.forward.app")
                        }

                        Button(role: .destructive) {
                            requestDeletion([document])
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        .help("Move transcript to Trash")
                        .disabled(isActive(document))
                    }
            } else {
                ContentUnavailableView(
                    "Select a transcript",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a note from the list to preview it.")
                )
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear {
            directoryMonitor.watch(appModel.outputDirectory)
            library.reload(from: appModel.outputDirectory)
        }
        .onChange(of: appModel.outputDirectory) {
            directoryMonitor.watch(appModel.outputDirectory)
            library.reload(from: appModel.outputDirectory)
        }
        .onChange(of: directoryMonitor.revision) {
            library.reload(from: appModel.outputDirectory)
        }
        .confirmationDialog(
            pendingDeletion.count == 1
                ? "Move this transcript to Trash?"
                : "Move \(pendingDeletion.count) transcripts to Trash?",
            isPresented: $isDeletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let documents = pendingDeletion
                guard !documents.isEmpty else { return }
                do {
                    try library.moveToTrash(documents)
                } catch {
                    operationError = error.localizedDescription
                    library.reload(from: appModel.outputDirectory)
                }
                pendingDeletion = []
                isDeletionConfirmationPresented = false
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = []
                isDeletionConfirmationPresented = false
            }
        } message: {
            if pendingDeletion.count == 1, let document = pendingDeletion.first {
                Text(
                    "“\(document.title)” and its diagnostics log can be recovered from macOS Trash."
                )
            } else if pendingDeletion.count > 1 {
                Text(
                    "\(pendingDeletion.count) transcripts and their diagnostics logs can be recovered from macOS Trash."
                )
            }
        }
        .sheet(item: $pendingRename) { document in
            RenameTranscriptView(
                currentTitle: document.title,
                onCancel: {
                    pendingRename = nil
                },
                onRename: { newTitle in
                    do {
                        try library.rename(
                            document,
                            to: newTitle,
                            in: appModel.outputDirectory
                        )
                    } catch {
                        operationError = error.localizedDescription
                        library.reload(from: appModel.outputDirectory)
                    }
                    pendingRename = nil
                }
            )
        }
        .alert(
            "Couldn’t Update Transcript",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK") {
                operationError = nil
            }
        } message: {
            Text(operationError ?? "An unknown error occurred.")
        }
    }

    private func isActive(_ document: TranscriptDocument) -> Bool {
        appModel.isRecording && document.url == appModel.transcriptURL
    }

    private func requestDeletion(_ documents: [TranscriptDocument]) {
        guard !documents.isEmpty else { return }
        pendingDeletion = documents
        isDeletionConfirmationPresented = true
    }
}

private struct MultiSelectionView: View {
    let count: Int

    var body: some View {
        ContentUnavailableView(
            "\(count) transcripts selected",
            systemImage: "doc.on.doc",
            description: Text(
                "Press Delete or use the trash button to move them to Trash."
            )
        )
    }
}

private struct RenameTranscriptView: View {
    let currentTitle: String
    let onCancel: () -> Void
    let onRename: (String) -> Void

    @State private var title: String
    @FocusState private var titleIsFocused: Bool

    init(
        currentTitle: String,
        onCancel: @escaping () -> Void,
        onRename: @escaping (String) -> Void
    ) {
        self.currentTitle = currentTitle
        self.onCancel = onCancel
        self.onRename = onRename
        _title = State(initialValue: currentTitle)
    }

    private var cleanedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rename transcript")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("The Markdown heading and filename will both be updated.")
                    .foregroundStyle(.secondary)
            }

            TextField("Transcript title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleIsFocused)
                .onSubmit(rename)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanedTitle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
        .onAppear {
            titleIsFocused = true
        }
    }

    private func rename() {
        guard !cleanedTitle.isEmpty else { return }
        onRename(cleanedTitle)
    }
}

private struct TranscriptPreview: View {
    let document: TranscriptDocument
    let isRenameDisabled: Bool
    let onTitleChange: (String) -> Void
    let onRename: (String) -> Bool

    @State private var draftTitle: String
    @State private var committedTitle: String
    @FocusState private var titleIsFocused: Bool

    init(
        document: TranscriptDocument,
        isRenameDisabled: Bool,
        onTitleChange: @escaping (String) -> Void,
        onRename: @escaping (String) -> Bool
    ) {
        self.document = document
        self.isRenameDisabled = isRenameDisabled
        self.onTitleChange = onTitleChange
        self.onRename = onRename
        _draftTitle = State(initialValue: document.title)
        _committedTitle = State(initialValue: document.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Transcript title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .focused($titleIsFocused)
                    .disabled(isRenameDisabled)
                    .help(
                        isRenameDisabled
                            ? "Stop transcription before renaming this note"
                            : "Click to edit; press Return to rename"
                    )
                    .onSubmit(commitTitle)
                    .onChange(of: draftTitle) { _, newTitle in
                        onTitleChange(newTitle)
                    }
                    .onExitCommand {
                        draftTitle = committedTitle
                        onTitleChange(committedTitle)
                        titleIsFocused = false
                    }
                    .onChange(of: titleIsFocused) { _, isFocused in
                        if !isFocused {
                            commitTitle()
                        }
                    }

                MarkdownDocumentView(markdown: markdownWithoutTitle)
            }
                .frame(maxWidth: 720, alignment: .topLeading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(document.title)
        .onChange(of: document.title) { _, newTitle in
            if !titleIsFocused {
                draftTitle = newTitle
                committedTitle = newTitle
            }
        }
    }

    private var cleanedTitle: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var markdownWithoutTitle: String {
        var lines = document.contents.components(separatedBy: .newlines)
        guard let headingIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }), lines[headingIndex].hasPrefix("# ") else {
            return document.contents
        }

        lines.remove(at: headingIndex)
        if lines.indices.contains(headingIndex),
           lines[headingIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: headingIndex)
        }
        return lines.joined(separator: "\n")
    }

    private func commitTitle() {
        guard !isRenameDisabled else {
            draftTitle = document.title
            return
        }
        guard !cleanedTitle.isEmpty else {
            draftTitle = document.title
            return
        }
        guard cleanedTitle != committedTitle else {
            draftTitle = committedTitle
            return
        }

        if onRename(cleanedTitle) {
            committedTitle = cleanedTitle
            draftTitle = cleanedTitle
        } else {
            draftTitle = committedTitle
            onTitleChange(committedTitle)
        }
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
