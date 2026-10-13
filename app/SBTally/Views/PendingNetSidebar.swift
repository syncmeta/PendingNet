import AppKit
import SwiftUI

/// AppKit owns row sizing, hit testing, keyboard navigation and group layout.
/// Only the selection colors differ from the system source-list defaults.
struct PendingNetSidebar: NSViewRepresentable {
    @Binding var selection: PendingNetSection?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.selectionHighlightStyle = .none
        outline.rowSizeStyle = .custom
        outline.rowHeight = 32
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 12
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.focusRingType = .none
        outline.backgroundColor = .clear
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.reloadData()
        context.coordinator.outline = outline
        context.coordinator.select(selection ?? .connection)
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.select(selection ?? .connection)
    }

    final class Node: NSObject {
        let section: PendingNetSection?
        let children: [Node] = []
        let isSpacer: Bool
        init(_ section: PendingNetSection? = nil, isSpacer: Bool = false) {
            self.section = section; self.isSpacer = isSpacer
        }
    }
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: PendingNetSidebar
        private var syncingSelection = false
        weak var outline: NSOutlineView?
        let statistics = Node()
        lazy var roots: [Node] = [.init(.connection), statistics, .init(.live), .init(.apps), .init(.domains), .init(isSpacer: true), .init(.logs), .init(.management), .init(.settings)]
        init(_ parent: PendingNetSidebar) { self.parent = parent }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !(item as! Node).children.isEmpty
        }
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as! Node).section == nil
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as! Node).section != nil
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let node = item as! Node
            let cell = NSTableCellView()
            if node.isSpacer { return cell }
            let text = NSTextField(labelWithString: node.section?.title ?? String(localized: "统计"))
            text.font = node.section == nil ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
            text.lineBreakMode = .byTruncatingTail
            cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            if let section = node.section {
                let image = NSImageView(image: NSImage(systemSymbolName: section.icon, accessibilityDescription: section.title) ?? NSImage())
                cell.imageView = image
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7)
                ])
            } else { text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true }
            NSLayoutConstraint.activate([
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4)
            ])
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            let node = item as! Node
            return node.isSpacer ? 12 : node.section == nil ? 24 : 32
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            PendingNetSidebarRow()
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline, let node = outline.item(atRow: outline.selectedRow) as? Node,
                  let section = node.section else { return }
            if !syncingSelection, parent.selection != section { parent.selection = section }
            refreshColors()
        }
        func select(_ section: PendingNetSection) {
            guard let outline else { return }
            for row in 0..<outline.numberOfRows {
                if (outline.item(atRow: row) as? Node)?.section == section {
                    if outline.selectedRow != row {
                        syncingSelection = true
                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        syncingSelection = false
                    }
                    break
                }
            }
            refreshColors()
        }
        private func refreshColors() {
            guard let outline else { return }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { continue }
                let isGroup = (outline.item(atRow: row) as? Node)?.section == nil
                let color = NSColor(row == outline.selectedRow ? PendingNetTheme.Palette.onAccent : isGroup ? PendingNetTheme.Palette.inkMuted : PendingNetTheme.Palette.ink)
                cell.textField?.textColor = color
                cell.imageView?.contentTintColor = color
            }
            outline.needsDisplay = true
        }
    }
}

final class PendingNetSidebarRow: NSTableRowView {
    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .none }
        set { }
    }
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(PendingNetTheme.Palette.accent).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) { }
}
