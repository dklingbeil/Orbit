import Foundation
import CoreGraphics

/// Every file tool Orbit offers.
public enum ToolID: String, CaseIterable, Sendable {
    // Images
    case imageCompress, imageResize, imageCrop, imageRotate, imageRemoveBackground, imageStripMetadata, imageExtractText, imagesToPDF
    // Video
    case videoCompress, videoTrim, videoCrop, videoRotate, videoResize, videoMute, videoSpeed, videoSnapshot, videoSplit, videoMerge
    // Audio
    case audioTrim, audioCompress, audioNormalize, audioSpeed, audioFade, audioSplit, audioMerge
    // PDF
    case pdfCompress, pdfSplit, pdfMerge, pdfRotate, pdfOCR, pdfProtect, pdfUnlock
    // Other
    case subtitleShift, archiveExtract, compressZip

    /// Tools that consume the whole selection at once and produce a single result.
    public var isCombined: Bool {
        switch self {
        case .imagesToPDF, .videoMerge, .audioMerge, .pdfMerge, .compressZip: return true
        default: return false
        }
    }
}

/// A single runnable operation: a conversion to a format, or a tool with an optional preset.
public struct OperationSpec: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case convert(FileFormat)
        case tool(ToolID)
    }

    public var kind: Kind
    /// Preset chosen on the wheel ("medium", "50", "left"…). `nil` means the tool's default.
    public var option: String?

    public init(_ kind: Kind, option: String? = nil) {
        self.kind = kind
        self.option = option
    }

    public static func convert(_ format: FileFormat) -> OperationSpec { OperationSpec(.convert(format)) }
    public static func tool(_ id: ToolID, _ option: String? = nil) -> OperationSpec { OperationSpec(.tool(id), option: option) }

    public var isCombined: Bool {
        if case .tool(let id) = kind { return id.isCombined }
        return false
    }

    public var description: String {
        switch kind {
        case .convert(let format): return "convert→\(format.id)"
        case .tool(let id): return option.map { "\(id.rawValue)(\($0))" } ?? id.rawValue
        }
    }
}

/// Extra input an operation needs from the user before it can run.
public enum InputRequirement: Hashable, Sendable {
    case none
    case text(title: String, message: String, placeholder: String, initial: String)
    case password(title: String, message: String, confirm: Bool)
    case trimRange
    case cropRect
}

/// Values gathered for an `InputRequirement`.
public struct OperationParameters: Sendable {
    public var text: String?
    public var password: String?
    public var trimStart: Double?
    public var trimEnd: Double?
    /// Crop rectangle in pixel coordinates with a top-left origin.
    public var cropRect: CGRect?

    public init(text: String? = nil, password: String? = nil, trimStart: Double? = nil, trimEnd: Double? = nil, cropRect: CGRect? = nil) {
        self.text = text
        self.password = password
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.cropRect = cropRect
    }
}

/// UI-agnostic menu tree that the wheel (and the CLI) renders.
public struct MenuNode: Identifiable, Sendable {
    public enum Payload: Hashable, Sendable {
        case none
        case operation(OperationSpec)
        /// App-defined action identifier (AirDrop, Float…), resolved by the host app.
        case action(String)
    }

    public var id: String
    public var title: String
    /// Sentence shown in the wheel's hub while hovering, e.g. "Convert to WebP".
    public var detail: String
    public var symbol: String?
    public var payload: Payload
    public var requirement: InputRequirement
    public var children: [MenuNode]
    public var disabledReason: String?

    public init(id: String, title: String, detail: String, symbol: String? = nil, payload: Payload = .none,
                requirement: InputRequirement = .none, children: [MenuNode] = [], disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.payload = payload
        self.requirement = requirement
        self.children = children
        self.disabledReason = disabledReason
    }

    public var isEnabled: Bool { disabledReason == nil }

    /// What a drop on this node runs: itself, or its first enabled child.
    public var resolved: MenuNode? {
        guard isEnabled else { return nil }
        if payload != .none { return self }
        return children.first(where: \.isEnabled)?.resolved
    }

    /// Depth-first search by id.
    public func find(_ id: String) -> MenuNode? {
        if self.id == id { return self }
        for child in children { if let hit = child.find(id) { return hit } }
        return nil
    }
}
