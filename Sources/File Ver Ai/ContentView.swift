import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Row Model

struct FileRow: Identifiable {
    let id = UUID()
    let url: URL
    let displayName: String
    let icon: NSImage
    let versionText: String
    let kindText: String
    /// A3（PDF - Illustrator 編集機能なし）相当の警告表示対象か
    let isWarning: Bool
    let sortMajor: Int
    let sortMinor: Int
    let sortPatch: Int
}

// MARK: - Supported Extensions

nonisolated enum SupportedExtensions {
    /// 明示的に受け付ける拡張子。拡張子なし（"")はパース後に判定するため別経路で扱う。
    static let set: Set<String> = ["ai", "ait", "pdf", "eps"]

    static func accept(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return false }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || set.contains(ext)
    }
}

// MARK: - ViewModel

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var rows: [FileRow] = []
    @Published var selectedID: UUID? = nil
    @Published var isProcessing: Bool = false
    /// 処理開始から spinnerDelay 秒経過した時点で true にする（短時間処理ではスピナーを出さない）
    @Published var showSpinner: Bool = false
    private static let spinnerDelay: Duration = .milliseconds(500)
    private var spinnerTask: Task<Void, Never>?

    func receive(urls: [URL]) {
        let targets = urls.filter { SupportedExtensions.accept($0) }
        rows = []
        selectedID = nil
        guard !targets.isEmpty else { return }

        isProcessing = true
        showSpinner = false
        spinnerTask?.cancel()
        spinnerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.spinnerDelay)
            guard !Task.isCancelled, let self, self.isProcessing else { return }
            self.showSpinner = true
        }
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: FileRow?.self) { group in
                for url in targets {
                    group.addTask { Self.parseRow(url: url) }
                }
                var collected: [FileRow] = []
                for await row in group {
                    if let row { collected.append(row) }
                }
                let result = collected
                await MainActor.run {
                    self.rows = result
                    self.isProcessing = false
                    self.showSpinner = false
                    self.spinnerTask?.cancel()
                }
            }
        }
    }

    private nonisolated static func parseRow(url: URL) -> FileRow? {
        let fc = FileParser.parse(url: url,
                                  timeLimit: 10.0,
                                  notDetectEPSCompatibleVer: true)

        let extLower = url.pathExtension.lowercased()
        let kind = kindText(for: fc)

        // 拡張子なしファイル: Illustrator 系でなければリストから除外（仕様§4）
        if extLower.isEmpty && !fc.isIllustratorFile {
            return nil
        }

        // 表示テキスト整形
        let versionText = formatVersion(fc: fc)
        let (sMajor, sMinor, sPatch) = extractVersionParts(from: versionText)
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        // A3 警告判定
        let isWarning = (fc.kind == "PDF" && !fc.isIllustratorFile)

        return FileRow(
            url: url,
            displayName: url.lastPathComponent,
            icon: icon,
            versionText: versionText,
            kindText: kind,
            isWarning: isWarning,
            sortMajor: sMajor,
            sortMinor: sMinor,
            sortPatch: sPatch
        )
    }

    /// 仕様§4 種類列の表記表に従って kind 文字列を決定する。
    private nonisolated static func kindText(for fc: AiFileModel) -> String {
        let isPhotoshop = (fc.appName == "Photoshop")
        switch fc.kind {
        case "PDF":
            return fc.isIllustratorFile
                ? String(localized: "PDF with Illustrator native data (.pdf)")
                : String(localized: "PDF without Illustrator native data (.pdf)")
        case "Ai":
            return fc.isTemplate
                ? String(localized: "Illustrator Template format (.ait)")
                : String(localized: "Adobe Illustrator format (.ai)")
        case "EPS":
            if fc.isIllustratorFile {
                return String(localized: "Illustrator EPS format (.eps)")
            } else if isPhotoshop {
                return String(localized: "Photoshop EPS format (.eps)")
            } else {
                return String(localized: "Unknown")
            }
        case "PSD":
            return String(localized: "Photoshop format (.psd)")
        default:
            return fc.kind
        }
    }

    /// 仕様§6 バージョン表示の整形:
    /// 1. 先頭 "Illustrator " を除去（appName + versionName + 生バージョンの組み合わせから生成）
    /// 2. カッコ内 (a.b.c.d) → (a.b.c)
    /// 3. 取得できない／対象外は空文字列
    private nonisolated static func formatVersion(fc: AiFileModel) -> String {
        guard fc.isIllustratorFile, !fc.determineCreated.isEmpty else { return "" }

        let alias = FileParser.versionName(fc.determineCreated)
        var text = "\(alias) (\(fc.determineCreated))"

        if let re = try? NSRegularExpression(pattern: #"\((\d+\.\d+\.\d+)(?:\.\d+)+\)"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "($1)")
        }
        return text
    }

    private nonisolated static func extractVersionParts(from versionText: String) -> (Int, Int, Int) {
        guard let re = try? NSRegularExpression(pattern: #"\((\d+)(?:\.(\d+))?(?:\.(\d+))?"#) else { return (0, 0, 0) }
        let range = NSRange(versionText.startIndex..., in: versionText)
        guard let m = re.firstMatch(in: versionText, range: range) else { return (0, 0, 0) }
        func part(_ i: Int) -> Int {
            guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: versionText) else { return 0 }
            return Int(versionText[r]) ?? 0
        }
        return (part(1), part(2), part(3))
    }
}

// MARK: - ContentView

enum SettingsKeys {
    static let listFontSize = "listFontSize"
}

struct ContentView: View {
    @StateObject private var vm = ContentViewModel()
    @State private var isDragOver = false
    @State private var sortedRows: [FileRow] = []
    @AppStorage(SettingsKeys.listFontSize) private var listFontSize: Int = 12

    var body: some View {
        ZStack {
            NativeList(
                columns: Self.columns,
                items: vm.rows,
                selection: $vm.selectedID,
                initialSort: (key: "fileName", ascending: true),
                fontSize: CGFloat(listFontSize),
                autosaveName: "FileList",
                onSortedItemsChange: { rows in sortedRows = rows },
                onDoubleClick: { row in
                    NSWorkspace.shared.activateFileViewerSelecting([row.url])
                },
                rowTextColor: { row in row.isWarning ? .systemRed : nil },
                rowIsBold: { row in row.isWarning }
            )

            if vm.rows.isEmpty && !vm.isProcessing {
                Text(String(localized: "placeholder.dropFiles"))
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }

            if vm.showSpinner {
                ProgressView()
                    .scaleEffect(2.0)
                    .allowsHitTesting(false)
            }
        }
        .background(dropOverlay)
        .onAppear {
            FileOpenHub.shared.handler = { [weak vm] urls in
                vm?.receive(urls: urls)
            }
            let pending = FileOpenHub.shared.drainPending()
            if !pending.isEmpty { vm.receive(urls: pending) }

            ExportHub.shared.handler = {
                exportCSV()
            }
            ExportHub.shared.canExportProvider = { !sortedRows.isEmpty }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            collectURLs(from: providers) { urls in
                vm.receive(urls: urls)
            }
            return true
        }
    }

    private static let columns: [NativeListColumn<FileRow>] = [
        NativeListColumn<FileRow>(
            id: "fileName",
            title: String(localized: "column.fileName"),
            { $0.displayName },
            icon: { $0.icon },
            minWidth: 120, width: 340
        ),
        NativeListColumn<FileRow>(
            id: "appVersion",
            title: String(localized: "column.appVersion"),
            { $0.versionText },
            minWidth: 80, width: 120,
            comparator: { lhs, rhs in
                if lhs.sortMajor != rhs.sortMajor {
                    return lhs.sortMajor < rhs.sortMajor ? .orderedAscending : .orderedDescending
                }
                if lhs.sortMinor != rhs.sortMinor {
                    return lhs.sortMinor < rhs.sortMinor ? .orderedAscending : .orderedDescending
                }
                if lhs.sortPatch != rhs.sortPatch {
                    return lhs.sortPatch < rhs.sortPatch ? .orderedAscending : .orderedDescending
                }
                return .orderedSame
            },
            secondaryComparator: { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName)
            }
        ),
        NativeListColumn<FileRow>(
            id: "kind",
            title: String(localized: "column.kind"),
            { $0.kindText },
            minWidth: 100, width: 170,
            secondaryComparator: { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName)
            }
        ),
    ]

    private var dropOverlay: some View {
        Group {
            if isDragOver {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - CSV export

    private func exportCSV() {
        let rows = sortedRows.isEmpty ? vm.rows : sortedRows
        guard !rows.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FileList.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let header = [
            String(localized: "column.fileName"),
            String(localized: "column.appVersion"),
            String(localized: "column.kind"),
        ]
        var lines: [String] = [header.map(Self.csvEscape).joined(separator: ",")]
        for r in rows {
            lines.append([r.displayName, r.versionText, r.kindText]
                .map(Self.csvEscape).joined(separator: ","))
        }
        let body = lines.joined(separator: "\r\n") + "\r\n"

        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(body.data(using: .utf8) ?? Data())
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private nonisolated static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func resolveAliasIfNeeded(_ url: URL) -> URL {
        let target = url.standardizedFileURL
        if let data = try? URL.bookmarkData(withContentsOf: target) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data,
                                       options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &stale) {
                return resolved
            }
        }
        if let resolved = try? URL(resolvingAliasFileAt: target, options: [.withoutUI]),
           resolved.path != target.path {
            return resolved
        }
        return target.resolvingSymlinksInPath()
    }

    private func collectURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var collected: [(Int, URL)] = []
        let lock = NSLock()
        for (idx, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    let resolved = Self.resolveAliasIfNeeded(url)
                    lock.lock()
                    collected.append((idx, resolved))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
            completion(urls)
        }
    }
}

// MARK: - ExportHub

@MainActor
final class ExportHub {
    static let shared = ExportHub()
    var handler: (() -> Void)?
    var canExportProvider: (() -> Bool)?

    func export() { handler?() }
    var canExport: Bool { canExportProvider?() ?? false }
}

// MARK: - FileOpenHub

@MainActor
final class FileOpenHub {
    static let shared = FileOpenHub()
    var handler: (([URL]) -> Void)?
    private var pending: [URL] = []

    func dispatch(_ urls: [URL]) {
        if let handler {
            handler(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    func drainPending() -> [URL] {
        let p = pending
        pending.removeAll()
        return p
    }
}

#Preview { ContentView() }
