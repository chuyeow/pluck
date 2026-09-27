import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Testing
@testable import PluckCore

// Renders black text on white, like text on a screen.
func renderText(_ lines: [String], size: CGFloat = 40) -> CGImage {
    let width = 1200, lineHeight = Int(size * 1.6), height = lineHeight * (lines.count + 1)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    for (i, line) in lines.enumerated() {
        let attr = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor.black,
        ])
        ctx.textPosition = CGPoint(x: 40, y: CGFloat(height - lineHeight * (i + 1)))
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
    return ctx.makeImage()!
}

func renderQR(_ payload: String) -> CGImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    // Quiet zone so the detector finds it.
    let padded = image.transformed(by: CGAffineTransform(translationX: 48, y: 48))
        .composited(over: CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -48, dy: -48).offsetBy(dx: 48, dy: 48)))
    return CIContext().createCGImage(padded, from: padded.extent)!
}

// Vision fails (e5rt error) when two requests cold-load its models concurrently.
@Suite(.serialized) struct VisionTests {
@Test func recognizesRenderedText() throws {
    let result = try Recognizer.recognize(renderText(["Pluck reads screens", "Second line 42"]))
    #expect(result.lines == ["Pluck reads screens", "Second line 42"])
    #expect(result.barcodes.isEmpty)
}

@Test func readsQRCode() throws {
    let result = try Recognizer.recognize(renderQR("https://example.com/pluck"))
    #expect(result.barcodes == ["https://example.com/pluck"])
}
}

@Test func barcodeWinsOverOCRNoise() {
    let r = Recognition(lines: ["garbage"], barcodes: ["https://a.b"])
    #expect(r.text(keepLineBreaks: true) == "https://a.b")
}

@Test func keepsOrJoinsLineBreaks() {
    let r = Recognition(lines: ["The quick brown", "fox jumps"], barcodes: [])
    #expect(r.text(keepLineBreaks: true) == "The quick brown\nfox jumps")
    #expect(r.text(keepLineBreaks: false) == "The quick brown fox jumps")
}

@Test func joiningRepairsHyphenatedWords() {
    let r = Recognition(lines: ["an extra-", "ordinary day"], barcodes: [])
    #expect(r.text(keepLineBreaks: false) == "an extraordinary day")
}

@Test func emptyWhenNothingFound() {
    #expect(Recognition(lines: [], barcodes: []).text(keepLineBreaks: true) == "")
}

@Test func appendsToExistingClipboard() {
    #expect(clipboardText(new: "b", existing: "a", append: true) == "a\nb")
    #expect(clipboardText(new: "b", existing: "a", append: false) == "b")
    #expect(clipboardText(new: "b", existing: nil, append: true) == "b")
    #expect(clipboardText(new: "b", existing: "", append: true) == "b")
    #expect(clipboardText(new: "b", existing: "a\n", append: true) == "a\nb")
}

@Test func shortcutDisplayAndCarbonFlags() {
    let s = Shortcut.default
    #expect(s.display == "⇧⌘2")
    #expect(s.carbonModifiers == 256 | 512) // cmdKey | shiftKey
    let all = Shortcut(keyCode: 0, key: "A", command: true, shift: true, option: true, control: true)
    #expect(all.display == "⌃⌥⇧⌘A")
    #expect(all.carbonModifiers == 256 | 512 | 2048 | 4096)
    #expect(all.keys == ["⌃", "⌥", "⇧", "⌘", "A"])
    #expect(Shortcut.default.keys == ["⇧", "⌘", "2"])
}

@Test func shortcutNeedsANonShiftModifier() {
    #expect(Shortcut(keyCode: 0, key: "A", command: false, shift: true, option: false, control: false).isValid == false)
    #expect(Shortcut(keyCode: 0, key: "A", command: false, shift: false, option: true, control: false).isValid)
}

@Test func shortcutRoundTripsThroughJSON() throws {
    let data = try JSONEncoder().encode(Shortcut.default)
    #expect(try JSONDecoder().decode(Shortcut.self, from: data) == .default)
}
