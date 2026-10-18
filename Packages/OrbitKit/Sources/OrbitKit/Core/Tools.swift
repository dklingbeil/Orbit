import Foundation

/// Routes a `ToolID` to the engine that implements it.
public enum Tools {
    public static func run(_ tool: ToolID, option: String?, inputs: [URL], context: JobContext) async throws -> [URL] {
        switch tool {
        case .imageCompress, .imageResize, .imageCrop, .imageRotate, .imageRemoveBackground,
             .imageStripMetadata, .imageExtractText, .imagesToPDF:
            return try await ImageTools.run(tool, option: option, inputs: inputs, context: context)

        case .videoCompress, .videoTrim, .videoCrop, .videoRotate, .videoResize, .videoMute,
             .videoSpeed, .videoSnapshot, .videoSplit, .videoMerge:
            return try await MediaTools.video(tool, option: option, inputs: inputs, context: context)

        case .audioTrim, .audioCompress, .audioNormalize, .audioSpeed, .audioFade, .audioSplit, .audioMerge:
            return try await MediaTools.audio(tool, option: option, inputs: inputs, context: context)

        case .pdfCompress, .pdfSplit, .pdfMerge, .pdfRotate, .pdfOCR, .pdfProtect, .pdfUnlock:
            return try await PDFTools.run(tool, option: option, inputs: inputs, context: context)

        case .subtitleShift:
            return try inputs.map { try SubtitleConverter.shift($0, option: option, context: context) }

        case .archiveExtract:
            var outputs: [URL] = []
            for input in inputs { outputs.append(try await ArchiveEngine.extract(input, context: context)) }
            return outputs

        case .compressZip:
            return [try await ArchiveEngine.zip(inputs, context: context)]
        }
    }
}
