import Foundation

/// Archives via the system's bsdtar (libarchive): ZIP/TAR/GZIP out, plus RAR and 7z in.
enum ArchiveEngine {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    private static let environment = ["COPYFILE_DISABLE": "1"]

    /// Extracts into a folder named after the archive. A lone top-level item is unwrapped.
    static func extract(_ input: URL, context: JobContext) async throws -> URL {
        let base = OutputNaming.baseName(of: input)
        let staging = try context.scratch("extract-\(UUID().uuidString)")
        context.progress(nil)

        if FormatDetector.format(for: input) == .gzip {
            // A bare .gz holds one file.
            let copy = staging.appendingPathComponent(input.lastPathComponent)
            try FileManager.default.copyItem(at: input, to: copy)
            try await ProcessRunner.checked(gzip, ["-d", copy.path], toolName: "gzip")
        } else {
            try await ProcessRunner.checked(tar, ["-xf", input.path, "-C", staging.path], environment: environment, toolName: "tar")
        }

        let fm = FileManager.default
        try? fm.removeItem(at: staging.appendingPathComponent("__MACOSX"))
        let items = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else { throw OrbitError.failed("\(input.lastPathComponent) is empty.") }

        if items.count == 1 {
            let destination = OutputNaming.uniqueURL(in: context.workDirectory, fileName: items[0].lastPathComponent)
            try fm.moveItem(at: items[0], to: destination)
            return destination
        }
        let folder = try context.outputFolder(named: base)
        for item in items {
            try fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
        }
        return folder
    }

    /// Packs `items` (which may live in different folders) into one archive.
    static func create(_ items: [URL], as format: FileFormat, base: String, context: JobContext) async throws -> URL {
        guard !items.isEmpty else { throw OrbitError.invalidInput("Nothing to compress.") }
        let output = context.output(base: base, ext: format.fileExtension)
        context.progress(nil)

        var parent = items[0].deletingLastPathComponent()
        var names = items.map(\.lastPathComponent)
        if !items.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) {
            let staging = try context.scratch("pack-\(UUID().uuidString)")
            names = []
            for item in items {
                let destination = OutputNaming.uniqueURL(in: staging, fileName: item.lastPathComponent)
                try FileManager.default.copyItem(at: item, to: destination)
                names.append(destination.lastPathComponent)
            }
            parent = staging
        }

        var args = ["-a", "-c", "-f", output.path, "--exclude", ".DS_Store", "--exclude", "__MACOSX"]
        if format == .tar { args = ["-c", "-f", output.path, "--exclude", ".DS_Store"] }
        args += ["-C", parent.path] + names
        try await ProcessRunner.checked(tar, args, environment: environment, toolName: "tar")
        return output
    }

    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, base: String, context: JobContext) async throws -> URL {
        if source == .folder {
            return try await create([input], as: target, base: base, context: context)
        }
        // Re-pack: extract into scratch, then archive the extracted contents.
        let staging = try context.scratch("repack-\(UUID().uuidString)")
        if source == .gzip {
            let copy = staging.appendingPathComponent(input.lastPathComponent)
            try FileManager.default.copyItem(at: input, to: copy)
            try await ProcessRunner.checked(gzip, ["-d", copy.path], toolName: "gzip")
        } else {
            try await ProcessRunner.checked(tar, ["-xf", input.path, "-C", staging.path], environment: environment, toolName: "tar")
        }
        try? FileManager.default.removeItem(at: staging.appendingPathComponent("__MACOSX"))
        let items = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else { throw OrbitError.failed("\(input.lastPathComponent) is empty.") }
        return try await create(items, as: target, base: base, context: context)
    }

    static func zip(_ inputs: [URL], context: JobContext) async throws -> URL {
        let base = inputs.count == 1 ? OutputNaming.baseName(of: inputs[0]) : "Archive"
        return try await create(inputs, as: .zip, base: base, context: context)
    }
}
