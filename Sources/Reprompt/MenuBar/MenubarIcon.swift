import AppKit

/// The menubar mark: two ragged lines of text resolving into one crisp caret. Clarify mode
/// breaks the caret, so the mode is readable at a glance without opening the menu.
///
/// The images are template images, so macOS tints them for light and dark menubars itself;
/// they must never carry colour of their own.
enum MenubarIcon {
    private static var cache: [Mode: NSImage] = [:]

    static func image(for mode: Mode) -> NSImage {
        if let cached = cache[mode] { return cached }
        let bytes = mode == .quick ? PackageResources.menubar_quick_png : PackageResources.menubar_clarify_png
        let image = NSImage(data: Data(bytes)) ?? NSImage()
        // Rendered at 2x and declared at 18pt, which is the standard menubar glyph height.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = mode == .quick ? "Reprompt, Quick mode" : "Reprompt, Clarify mode"
        cache[mode] = image
        return image
    }
}
