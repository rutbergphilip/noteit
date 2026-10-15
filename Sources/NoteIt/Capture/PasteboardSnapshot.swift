import AppKit

/// A deep copy of every item on a pasteboard, so it can be put back after a temporary write.
struct PasteboardSnapshot {
    private struct Entry {
        var type: NSPasteboard.PasteboardType
        var data: Data
    }

    private let items: [[Entry]]

    init(_ pasteboard: NSPasteboard) {
        let source = pasteboard.pasteboardItems ?? []
        items = source.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return Entry(type: type, data: data)
            }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.compactMap { entries in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
