import SwiftUI
import AppKit

// MARK: - NativeListColumn

/// NativeList の列定義。
struct NativeListColumn<Item> {
    /// 列の永続識別子（ローカライズしない）。autosave キーに使う。
    let id: String
    let title: String
    let value: (Item) -> String
    var icon: ((Item) -> NSImage?)? = nil
    var isBold: (Item) -> Bool
    var minWidth: CGFloat = 60
    var width: CGFloat?
    var alignment: NSTextAlignment = .natural
    /// 独自比較。nil の場合は value を localizedStandardCompare で比較。
    var comparator: ((Item, Item) -> ComparisonResult)? = nil
    /// 主キーが同値のときに使う第2比較。常に昇順で適用される。
    var secondaryComparator: ((Item, Item) -> ComparisonResult)? = nil

    init(id: String,
         title: String,
         _ value: @escaping (Item) -> String,
         icon: ((Item) -> NSImage?)? = nil,
         isBold: @escaping (Item) -> Bool = { _ in false },
         minWidth: CGFloat = 60,
         width: CGFloat? = nil,
         alignment: NSTextAlignment = .natural,
         comparator: ((Item, Item) -> ComparisonResult)? = nil,
         secondaryComparator: ((Item, Item) -> ComparisonResult)? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.icon = icon
        self.isBold = isBold
        self.minWidth = minWidth
        self.width = width
        self.alignment = alignment
        self.comparator = comparator
        self.secondaryComparator = secondaryComparator
    }
}

// MARK: - NativeList

/// NSTableView を直接ラップした SwiftUI ビュー。
/// - ヘッダ表示・複数列・Finder 風ソートに対応。
/// - 列ヘッダクリックで昇順／降順を切替。
struct NativeList<Item: Identifiable>: NSViewRepresentable {
    let columns: [NativeListColumn<Item>]
    let items: [Item]
    @Binding var selection: Item.ID?
    /// 初期ソート (列 id, 昇順)
    var initialSort: (key: String, ascending: Bool)? = nil
    /// セルのフォントサイズ（pt）
    var fontSize: CGFloat = 12
    /// NSTableView の autosaveName。指定すると列幅・順序・ソートが自動保存される。
    var autosaveName: String? = nil
    /// ソート済み（表示順）の items が更新されるたびに呼ばれる。
    var onSortedItemsChange: (([Item]) -> Void)? = nil
    var onDoubleClick: ((Item) -> Void)? = nil
    /// 行ごとの文字色。返り値 nil なら既定色。全列に一律適用される。
    var rowTextColor: ((Item) -> NSColor?)? = nil
    /// 行ごとの Bold 指定。true なら全列を Bold で描画（列の isBold より優先）。
    var rowIsBold: ((Item) -> Bool)? = nil

    /// fontSize に対する行高。14pt のみ 22。
    private static func rowHeight(for size: CGFloat) -> CGFloat {
        size >= 14 ? 22 : 20
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(columns: columns)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTableView()
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.usesAlternatingRowBackgroundColors = true
        tv.style = .fullWidth
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.focusRingType = .none
        tv.rowHeight = Self.rowHeight(for: fontSize)
        context.coordinator.currentFontSize = fontSize
        tv.allowsMultipleSelection = false
        tv.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tv.allowsColumnReordering = false
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.doubleClicked(_:))

        for (i, col) in columns.enumerated() {
            let tc = NSTableColumn(identifier: .init(col.id))
            tc.title = col.title
            tc.minWidth = col.minWidth
            if let w = col.width { tc.width = w }
            tc.headerCell.alignment = col.alignment
            // 全列ユーザーリサイズ可。先頭列は残幅も吸収（Finder準拠）。
            tc.resizingMask = (i == 0) ? [.userResizingMask, .autoresizingMask] : .userResizingMask
            tc.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)
            tv.addTableColumn(tc)
        }

        tv.headerView = CompactHeaderView()

        if let name = autosaveName {
            tv.autosaveName = name
            tv.autosaveTableColumns = true
        }

        if let init0 = initialSort {
            tv.sortDescriptors = [NSSortDescriptor(key: init0.key, ascending: init0.ascending)]
        }

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.verticalScrollElasticity = .automatic
        sv.borderType = .noBorder
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        tv.sizeLastColumnToFit()
        context.coordinator.tableView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.onDoubleClick = onDoubleClick
        coord.onSortedItemsChange = onSortedItemsChange
        coord.rowTextColor = rowTextColor
        coord.rowIsBold = rowIsBold
        coord.selectionChanged = { newID in
            if selection != newID { selection = newID }
        }

        if coord.currentFontSize != fontSize {
            coord.currentFontSize = fontSize
            coord.tableView?.rowHeight = Self.rowHeight(for: fontSize)
            coord.tableView?.reloadData()
        }

        let newIDs = items.map(\.id)
        if newIDs != coord.sourceIDs {
            coord.sourceItems = items
            coord.sourceIDs = newIDs
            coord.isUpdating = true
            coord.applySorting()
            coord.tableView?.reloadData()
            coord.isUpdating = false
            coord.onSortedItemsChange?(coord.sortedItems)
        }

        guard let tv = coord.tableView else { return }
        let targetRow = selection.flatMap { sel in
            coord.sortedItems.firstIndex(where: { $0.id == sel })
        }
        let currentRow = tv.selectedRow >= 0 ? tv.selectedRow : nil
        if targetRow != currentRow {
            coord.isUpdating = true
            if let row = targetRow {
                tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tv.scrollRowToVisible(row)
            } else {
                tv.deselectAll(nil)
            }
            coord.isUpdating = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let columns: [NativeListColumn<Item>]
        var sourceItems: [Item] = []
        var sourceIDs: [Item.ID] = []
        var sortedItems: [Item] = []
        var onDoubleClick: ((Item) -> Void)?
        var onSortedItemsChange: (([Item]) -> Void)?
        var selectionChanged: ((Item.ID?) -> Void)?
        var rowTextColor: ((Item) -> NSColor?)?
        var rowIsBold: ((Item) -> Bool)?
        var isUpdating = false
        var currentFontSize: CGFloat = 12
        weak var tableView: NSTableView?

        init(columns: [NativeListColumn<Item>]) {
            self.columns = columns
        }

        // 明示的な deinit。
        // Xcode 26 系の swiftc が `-O -whole-module-optimization` 下で
        // 合成された deinit を EarlyPerfInliner で最適化中にクラッシュする問題への回避策。
        // 中身は空でよい（合成 deinit と同じ動作）。
        deinit {}

        func applySorting() {
            guard let tv = tableView, !tv.sortDescriptors.isEmpty else {
                sortedItems = sourceItems
                return
            }
            sortedItems = sorted(sourceItems, by: tv.sortDescriptors)
        }

        private func sorted(_ items: [Item], by descriptors: [NSSortDescriptor]) -> [Item] {
            guard let desc = descriptors.first, let key = desc.key,
                  let col = columns.first(where: { $0.id == key }) else {
                return items
            }
            return items.sorted { lhs, rhs in
                let cmp: ComparisonResult
                if let custom = col.comparator {
                    cmp = custom(lhs, rhs)
                } else {
                    cmp = col.value(lhs).localizedStandardCompare(col.value(rhs))
                }
                if cmp != .orderedSame {
                    return desc.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
                if let sec = col.secondaryComparator {
                    return sec(lhs, rhs) == .orderedAscending
                }
                return false
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            sortedItems.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            let selectedID: Item.ID? = {
                let row = tableView.selectedRow
                guard row >= 0, row < sortedItems.count else { return nil }
                return sortedItems[row].id
            }()
            isUpdating = true
            sortedItems = sorted(sourceItems, by: tableView.sortDescriptors)
            onSortedItemsChange?(sortedItems)
            tableView.reloadData()
            if let sel = selectedID,
               let row = sortedItems.firstIndex(where: { $0.id == sel }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            }
            isUpdating = false
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tc = tableColumn,
                  let col = columns.first(where: { $0.id == tc.identifier.rawValue }),
                  row < sortedItems.count else { return nil }
            let item = sortedItems[row]

            if col.icon != nil {
                return makeIconCell(col: col, item: item, tableView: tableView)
            } else {
                return makeTextCell(col: col, item: item, tableView: tableView)
            }
        }

        private func makeTextCell(col: NativeListColumn<Item>, item: Item, tableView: NSTableView) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("text_\(col.id)")
            let cellView: NSTableCellView
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView,
               let tf = reused.textField {
                cellView = reused
                field = tf
            } else {
                cellView = NSTableCellView()
                cellView.identifier = cellID
                field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cellView.addSubview(field)
                cellView.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            }
            field.alignment = col.alignment
            field.stringValue = col.value(item)
            applyStyle(field: field, col: col, item: item)
            return cellView
        }

        private func makeIconCell(col: NativeListColumn<Item>, item: Item, tableView: NSTableView) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("icon_\(col.id)")
            let cellView: NSTableCellView
            let field: NSTextField
            let imageView: NSImageView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView,
               let tf = reused.textField, let iv = reused.imageView {
                cellView = reused
                field = tf
                imageView = iv
            } else {
                cellView = NSTableCellView()
                cellView.identifier = cellID
                imageView = NSImageView()
                imageView.imageScaling = .scaleProportionallyDown
                imageView.translatesAutoresizingMaskIntoConstraints = false
                field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cellView.addSubview(imageView)
                cellView.addSubview(field)
                cellView.imageView = imageView
                cellView.textField = field
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            }
            imageView.image = col.icon?(item)
            field.alignment = col.alignment
            field.stringValue = col.value(item)
            applyStyle(field: field, col: col, item: item)
            return cellView
        }

        private func applyStyle(field: NSTextField, col: NativeListColumn<Item>, item: Item) {
            let size: CGFloat = currentFontSize
            let bold = (rowIsBold?(item) ?? false) || col.isBold(item)
            field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            field.textColor = rowTextColor?(item) ?? .labelColor
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTableView else { return }
            let row = tv.selectedRow
            selectionChanged?(row >= 0 && row < sortedItems.count ? sortedItems[row].id : nil)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < sortedItems.count else { return }
            onDoubleClick?(sortedItems[row])
        }
    }
}

// MARK: - CompactHeaderView

private class CompactHeaderView: NSTableHeaderView {
    var headerHeight: CGFloat = 19
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: headerHeight)
    }
    override func layout() {
        super.layout()
        if frame.height != headerHeight {
            frame.size.height = headerHeight
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        let y = bounds.maxY - 0.5
        let path = NSBezierPath()
        path.lineWidth = 1.0
        path.move(to: NSPoint(x: bounds.minX, y: y))
        path.line(to: NSPoint(x: bounds.maxX, y: y))
        path.stroke()
    }
}
