import Foundation

/// File naming and final placement of produced files.
public enum OutputNaming {
    /// Splits "Report.final.tar.gz" into ("Report.final", "tar.gz").
    public static func split(_ fileName: String) -> (base: String, ext: String) {
        if let ext = FormatDetector.matchedExtension(for: fileName), FormatDetector.format(forExtension: ext) != nil {
            let base = String(fileName.dropLast(ext.count + 1))
            return (base.isEmpty ? fileName : base, base.isEmpty ? "" : ext)
        }
        let ns = fileName as NSString
        return (ns.deletingPathExtension, ns.pathExtension)
    }

    public static func baseName(of url: URL) -> String {
        split(url.lastPathComponent).base
    }

    public static func fileName(base: String, ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Returns `dir/fileName`, or `dir/name 2.ext`, `dir/name 3.ext`… if taken.
    public static func uniqueURL(in directory: URL, fileName: String, fileManager: FileManager = .default) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let (base, ext) = split(fileName)
        var index = 2
        while true {
            let next = directory.appendingPathComponent(self.fileName(base: "\(base) \(index)", ext: ext))
            if !fileManager.fileExists(atPath: next.path) { return next }
            index += 1
        }
    }

    /// Moves produced items into `directory` without overwriting anything.
    public static func place(_ items: [URL], into directory: URL, fileManager: FileManager = .default) throws -> [URL] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try items.map { item in
            let destination = uniqueURL(in: directory, fileName: item.lastPathComponent, fileManager: fileManager)
            try fileManager.moveItem(at: item, to: destination)
            return destination
        }
    }

    /// A fresh scratch directory, preferably on the same volume as `near` so final moves are cheap.
    public static func makeWorkDirectory(near: URL?) throws -> URL {
        let fm = FileManager.default
        if let near,
           let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: near, create: true) {
            return dir
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("Orbit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
