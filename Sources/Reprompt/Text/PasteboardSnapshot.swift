import AppKit

/// A copy of a pasteboard's contents, taken so the clipboard-based grab and paste can put
/// things back exactly as they were.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    /// True when the pasteboard held items at capture time.
    private let hadItems: Bool
    let changeCount: Int

    /// Capture is best-effort: a source application can decline to materialise a promised
    /// representation, and it may have quit entirely.
    static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot {
        let existing = pb.pasteboardItems ?? []
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in existing {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { entry[type] = d }
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return PasteboardSnapshot(items: items, hadItems: !existing.isEmpty, changeCount: pb.changeCount)
    }

    /// True when the capture is a faithful record of what was on the pasteboard.
    var isReliable: Bool { hadItems == !items.isEmpty }

    /// Puts the captured contents back. When the capture failed to read anything from a
    /// pasteboard that did hold items, the contents are left alone: the original is already
    /// unrecoverable, and clearing on top of that would destroy the replacement too.
    func restore(to pb: NSPasteboard = .general) {
        guard isReliable else { return }
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
    var typeCount: Int { items.reduce(0) { $0 + $1.count } }
}
