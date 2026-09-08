import AppKit

/// Full copy of the general pasteboard so the clipboard-based grab and paste leave no trace.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int

    static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { entry[type] = d }
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return PasteboardSnapshot(items: items, changeCount: pb.changeCount)
    }

    func restore(to pb: NSPasteboard = .general) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }

    var isEmpty: Bool { items.isEmpty }
}
