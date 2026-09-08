import AppKit
import Testing
@testable import Reprompt

/// Declares a type and then never provides its data, like a source app that has quit.
final class NullDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {}
}

@Suite @MainActor struct PasteboardSnapshotTests {
    /// A private pasteboard, so the user's real clipboard is never touched by a test.
    func scratchPasteboard() -> (NSPasteboard, () -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.holdenrichard.reprompt.tests.\(UUID().uuidString)"))
        return (pb, { pb.releaseGlobally() })
    }

    @Test func restoresPlainTextExactly() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("the user's clipboard", forType: .string)

        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.isReliable)
        pb.clearContents()
        pb.setString("Reprompt's temporary value", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "the user's clipboard")
    }

    @Test func restoresEveryRepresentationOfAnItem() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("plain".utf8), forType: .string)
        item.setData(Data("<html>rich</html>".utf8), forType: .html)
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.typeCount >= 2)
        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "plain")
        #expect(pb.data(forType: .html) == Data("<html>rich</html>".utf8))
    }

    @Test func restoresMultipleItems() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        let a = NSPasteboardItem(); a.setData(Data("one".utf8), forType: .string)
        let b = NSPasteboardItem(); b.setData(Data("two".utf8), forType: .string)
        pb.writeObjects([a, b])

        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        snapshot.restore(to: pb)
        #expect(pb.pasteboardItems?.count == 2)
        #expect(pb.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["one", "two"])
    }

    /// An empty clipboard must come back empty: leaving Reprompt's copied text behind would
    /// interfere with the user's normal clipboard use.
    @Test func anEmptyClipboardIsRestoredAsEmpty() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.isEmpty)
        #expect(snapshot.isReliable)
        pb.setString("copied selection", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }

    /// A source app can declare a type and then decline to produce the data (it may have
    /// quit). The capture is then a lie, and clearing on top of it would destroy the
    /// replacement text too, leaving the user with nothing at all.
    @Test func anUnreliableCaptureDoesNotWipeTheClipboard() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        let provider = NullDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(pb)
        guard !snapshot.isReliable else {
            Issue.record("the promised type resolved, so this environment cannot exercise the case")
            return
        }
        pb.clearContents()
        pb.setString("Reprompt's rewrite", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "Reprompt's rewrite",
                "an unrecoverable original must not be replaced with nothing")
    }

    @Test func captureRecordsTheChangeCount() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("x", forType: .string)
        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.changeCount == pb.changeCount)
        pb.clearContents()
        #expect(snapshot.changeCount != pb.changeCount)
    }

    @Test func restoringTwiceIsHarmless() {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("value", forType: .string)
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        snapshot.restore(to: pb)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "value")
        #expect(pb.pasteboardItems?.count == 1)
    }
}

@Suite @MainActor struct OverlayPlacementTests {
    let size = NSSize(width: 520, height: 380)
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1055)

    @Test func nearCursorPlacesThePanelBelowAndRightOfThePointer() {
        let f = OverlayController.frame(size: size, mouse: NSPoint(x: 800, y: 600),
                                        visibleFrame: screen, position: .cursor)
        let expectedX: CGFloat = 800 + 12
        let expectedY: CGFloat = 600 - 380 - 12
        #expect(f.origin.x == expectedX)
        #expect(f.origin.y == expectedY)
        #expect(f.size == size)
    }

    @Test func theCenterOptionCentresOnTheVisibleFrame() {
        let f = OverlayController.frame(size: size, mouse: NSPoint(x: 0, y: 0),
                                        visibleFrame: screen, position: .screenCenter)
        #expect(f.midX == screen.midX)
        #expect(f.midY == screen.midY)
    }

    @Test func thePanelIsClampedInsideTheVisibleFrame() {
        for mouse in [NSPoint(x: 1919, y: 1054), NSPoint(x: 0, y: 0),
                      NSPoint(x: 1919, y: 0), NSPoint(x: 0, y: 1054)] {
            let f = OverlayController.frame(size: size, mouse: mouse, visibleFrame: screen, position: .cursor)
            #expect(screen.contains(f), "panel escaped the screen for mouse \(mouse): \(f)")
        }
    }

    /// A display to the left of the main one has a negative origin.
    @Test func clampingWorksOnANegativeOriginDisplay() {
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        for mouse in [NSPoint(x: -1, y: 1054), NSPoint(x: -1920, y: 0), NSPoint(x: -1000, y: 500)] {
            let f = OverlayController.frame(size: size, mouse: mouse, visibleFrame: left, position: .cursor)
            #expect(left.contains(f), "panel escaped the left display for mouse \(mouse): \(f)")
        }
    }

    @Test func aScreenSmallerThanThePanelStillPlacesItsTopLeftOnScreen() {
        let tiny = NSRect(x: 0, y: 0, width: 300, height: 200)
        let f = OverlayController.frame(size: size, mouse: NSPoint(x: 150, y: 100),
                                        visibleFrame: tiny, position: .cursor)
        #expect(f.origin.x == tiny.minX + 8)
        #expect(f.origin.y == tiny.minY + 8)
    }
}
