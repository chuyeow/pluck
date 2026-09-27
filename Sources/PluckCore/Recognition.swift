import CoreGraphics
import Vision

/// What Vision found in an image: text lines in reading order, plus any barcode payloads.
public struct Recognition: Equatable, Sendable {
    public var lines: [String]
    public var barcodes: [String]

    public init(lines: [String], barcodes: [String]) {
        self.lines = lines
        self.barcodes = barcodes
    }

    /// Barcodes win: OCR over a QR code is noise, the payload is what the user wants.
    public func text(keepLineBreaks: Bool) -> String {
        if !barcodes.isEmpty { return barcodes.joined(separator: "\n") }
        if keepLineBreaks { return lines.joined(separator: "\n") }
        return lines.reduce("") { acc, line in
            if acc.isEmpty { return line }
            if acc.hasSuffix("-") { return acc.dropLast() + line }
            return acc + " " + line
        }
    }
}

public enum Recognizer {
    public static func recognize(_ image: CGImage) throws -> Recognition {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let barcodes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, barcodes])
        return Recognition(
            lines: (text.results ?? []).compactMap { $0.topCandidates(1).first?.string },
            barcodes: (barcodes.results ?? []).compactMap(\.payloadStringValue)
        )
    }
}

public func clipboardText(new: String, existing: String?, append: Bool) -> String {
    guard append, let existing, !existing.isEmpty else { return new }
    return existing + "\n" + new
}
