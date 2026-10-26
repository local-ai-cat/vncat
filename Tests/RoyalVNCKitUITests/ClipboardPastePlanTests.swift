import Testing

@testable import RoyalVNCKitUI

@Suite("Clipboard paste plan")
struct ClipboardPastePlanTests {
    @Test("Text alone pastes as text")
    func textOnly() {
        #expect(ClipboardPastePlan.choose(string: "hello", hasImage: false) == .text("hello"))
    }

    @Test("An image alone pastes as an image")
    func imageOnly() {
        #expect(ClipboardPastePlan.choose(string: nil, hasImage: true) == .image)
        #expect(ClipboardPastePlan.choose(string: "", hasImage: true) == .image)
    }

    @Test("An image copied with its web address pastes the image")
    func imageWithItsURL() {
        #expect(ClipboardPastePlan.choose(string: "https://example.com/cat.png", hasImage: true) == .image)
        #expect(ClipboardPastePlan.choose(string: " http://example.com/a \n", hasImage: true) == .image)
    }

    @Test("Real text next to an image stays text")
    func proseBeatsImage() {
        #expect(ClipboardPastePlan.choose(string: "see https://example.com", hasImage: true) == .text("see https://example.com"))
        #expect(ClipboardPastePlan.choose(string: "file:///tmp/a.png", hasImage: true) == .text("file:///tmp/a.png"))
    }

    @Test("An empty clipboard pastes nothing")
    func empty() {
        #expect(ClipboardPastePlan.choose(string: nil, hasImage: false) == .nothing)
        #expect(ClipboardPastePlan.choose(string: "", hasImage: false) == .nothing)
    }
}
