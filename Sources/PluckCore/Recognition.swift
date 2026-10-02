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
    /// Apple's model runtime (e5rt) can fail to set up Vision's accurate text model, surfacing as
    /// CRImageReaderError 1 or e5rtError ("create_precompiled_compute_operation", Code 13). Seen when
    /// the disk is nearly full: the compiled model can't be cached, the first call works and later ones fail.
    /// Vision's own errors (VNErrorDomain, e.g. a selection too small to read) won't change with another model.
    public static func isModelFailure(_ error: Error) -> Bool {
        (error as NSError).domain != VNErrorDomain
    }

    /// Accurate first; on a model failure, the fast model, which is small and keeps working.
    public static func recognize(_ image: CGImage, onFallback: (Error) -> Void = { _ in }) throws -> Recognition {
        try withFallback(onFallback: onFallback) { try recognizeOnce(image, level: $0) }
    }

    static func withFallback(
        onFallback: (Error) -> Void = { _ in },
        _ attempt: (VNRequestTextRecognitionLevel) throws -> Recognition
    ) throws -> Recognition {
        do {
            return try attempt(.accurate)
        } catch where isModelFailure(error) {
            onFallback(error)
            return try attempt(.fast)
        }
    }

    static func recognizeOnce(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> Recognition {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = level
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
    return existing.hasSuffix("\n") ? existing + new : existing + "\n" + new
}
