import Foundation

public enum CellValue: Sendable, Equatable {
    case empty
    case string(String)
    case number(Double)
    case bool(Bool)

    /// Interprets CSV text: numbers become numeric cells (but not things like "007" or phone numbers).
    static func infer(_ raw: String) -> CellValue {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .empty }
        let looksNumeric = text.firstMatch(of: #/^-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?$/#) != nil
        if looksNumeric, text.count <= 15, let value = Double(text) { return .number(value) }
        return .string(raw)
    }

    var text: String {
        switch self {
        case .empty: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        }
    }

    var isEmpty: Bool {
        if case .empty = self { return true }
        if case .string(let s) = self { return s.isEmpty }
        return false
    }
}

public struct Sheet: Sendable {
    public var name: String
    public var rows: [[CellValue]]

    public init(name: String, rows: [[CellValue]]) {
        self.name = name
        self.rows = rows
    }

    /// Drops trailing empty cells and rows.
    func trimmed() -> Sheet {
        var rows = self.rows.map { row -> [CellValue] in
            var r = row
            while let last = r.last, last.isEmpty { r.removeLast() }
            return r
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return Sheet(name: name, rows: rows)
    }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

public struct Workbook: Sendable {
    public var sheets: [Sheet]
    public init(sheets: [Sheet]) { self.sheets = sheets }
}

enum CSV {
    static func parse(_ text: String, delimiter: Character? = nil) -> [[String]] {
        var input = text
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
        let separator = delimiter ?? detectDelimiter(input)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = input.makeIterator()
        var pending: Character? = nil

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty:
                inQuotes = true
            case separator:
                row.append(field); field = ""
            case "\r\n", "\n", "\r":
                row.append(field); field = ""
                rows.append(row); row = []
            default:
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func detectDelimiter(_ text: String) -> Character {
        let sample = text.prefix(8000)
        let firstLines = sample.split(whereSeparator: \.isNewline).prefix(5)
        var best: Character = ","
        var bestScore = 0
        for candidate in [",", ";", "\t", "|"] as [Character] {
            let counts = firstLines.map { line -> Int in
                var inQuotes = false
                var count = 0
                for c in line {
                    if c == "\"" { inQuotes.toggle() } else if c == candidate && !inQuotes { count += 1 }
                }
                return count
            }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = counts.allSatisfy { $0 == first }
            let score = first * (consistent ? 3 : 1)
            if score > bestScore { best = candidate; bestScore = score }
        }
        return best
    }

    static func write(_ rows: [[CellValue]], delimiter: Character) -> String {
        rows.map { row in
            row.map { cell -> String in
                let text = cell.text
                if delimiter == "\t" {
                    return text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                }
                if text.contains(delimiter) || text.contains("\"") || text.contains("\n") || text.contains("\r") {
                    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return text
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }
}

/// Writes a workbook in any supported spreadsheet format.
enum SpreadsheetWriter {
    static func write(_ workbook: Workbook, as target: FileFormat, to url: URL) throws {
        let sheets = workbook.sheets.map { $0.trimmed() }
        switch target {
        case .csv:
            try CSV.write(sheets.first?.rows ?? [], delimiter: ",").write(to: url, atomically: true, encoding: .utf8)
        case .tsv:
            try CSV.write(sheets.first?.rows ?? [], delimiter: "\t").write(to: url, atomically: true, encoding: .utf8)
        case .xlsx:
            try XLSXWriter.write(Workbook(sheets: sheets), to: url)
        case .ods:
            try ODSWriter.write(Workbook(sheets: sheets), to: url)
        case .pdf:
            try SpreadsheetPDF.write(Workbook(sheets: sheets), to: url)
        default:
            throw OrbitError.unsupported("writing \(target.name) spreadsheets")
        }
    }
}

enum SpreadsheetConverter {
    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, base: String, context: JobContext) async throws -> [URL] {
        let caps = context.capabilities
        context.progress(nil)

        // Office renderers keep formatting when printing native workbooks to PDF.
        if target == .pdf, source != .csv, source != .tsv {
            let output = context.output(base: base, ext: "pdf")
            if source == .numbers, caps.iwork.numbers {
                try await IWork.export(input, with: .numbers, as: .pdf, to: output)
                return [output]
            }
            if let office = caps.libreOffice {
                let produced = try await office.convert(input, to: "pdf", outputDirectory: try context.scratch())
                try FileManager.default.moveItem(at: produced, to: output)
                return [output]
            }
        }

        let workbook = try await read(input, format: source, context: context)
        guard workbook.sheets.contains(where: { !$0.trimmed().rows.isEmpty }) else {
            throw OrbitError.failed("\(input.lastPathComponent) has no data.")
        }

        // CSV/TSV hold one sheet each: write one file per non-empty sheet.
        if target == .csv || target == .tsv {
            let sheets = workbook.sheets.map { $0.trimmed() }.filter { !$0.rows.isEmpty }
            if sheets.count > 1 {
                return try sheets.map { sheet in
                    let safe = sheet.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    let url = context.output(base: "\(base) - \(safe)", ext: target.fileExtension)
                    try SpreadsheetWriter.write(Workbook(sheets: [sheet]), as: target, to: url)
                    return url
                }
            }
        }
        let output = context.output(base: base, ext: target.fileExtension)
        try SpreadsheetWriter.write(workbook, as: target, to: output)
        return [output]
    }

    static func read(_ input: URL, format: FileFormat, context: JobContext) async throws -> Workbook {
        let name = OutputNaming.baseName(of: input)
        switch format {
        case .csv:
            let rows = CSV.parse(try DocumentConverter.readText(input)).map { $0.map(CellValue.infer) }
            return Workbook(sheets: [Sheet(name: name, rows: rows)])
        case .tsv:
            let rows = CSV.parse(try DocumentConverter.readText(input), delimiter: "\t").map { $0.map(CellValue.infer) }
            return Workbook(sheets: [Sheet(name: name, rows: rows)])
        case .xlsx:
            return try XLSXReader.read(input)
        case .ods:
            return try ODSReader.read(input)
        case .xls, .numbers:
            let scratch = try context.scratch()
            if format == .numbers || context.capabilities.libreOffice == nil, context.capabilities.iwork.numbers {
                let xlsx = scratch.appendingPathComponent("\(name).xlsx")
                try await IWork.export(input, with: .numbers, as: .excel, to: xlsx)
                return try XLSXReader.read(xlsx)
            }
            guard let office = context.capabilities.libreOffice else {
                throw OrbitError.missingTool("Reading \(format.name) files requires Numbers or LibreOffice.")
            }
            return try XLSXReader.read(try await office.convert(input, to: "xlsx", outputDirectory: scratch))
        default:
            throw OrbitError.unsupported("reading \(format.name) as a spreadsheet")
        }
    }
}
