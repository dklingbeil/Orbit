import CoreGraphics
import Foundation
import Vision

/// On-device OCR (Vision) shared by the image "Text" tool and scanned-PDF conversions.
enum TextRecognizer {
    struct Line {
        let text: String
        /// Normalized bounding box, origin at the bottom-left.
        let box: CGRect
    }

    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox)
        }
        return lines.sorted { a, b in
            abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5 ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }
    }

    /// Groups recognized lines into paragraphs using vertical gaps.
    static func paragraphs(from lines: [Line]) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var previous: Line?
        for line in lines {
            if let previous {
                let gap = previous.box.minY - line.box.maxY
                if gap > previous.box.height * 0.8 {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
            }
            current.append(line.text)
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.filter { !$0.isEmpty }
    }

    static func text(in image: CGImage) throws -> String {
        paragraphs(from: try recognize(image)).joined(separator: "\n\n")
    }
}
