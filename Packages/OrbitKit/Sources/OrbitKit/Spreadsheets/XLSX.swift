import Foundation

enum XLSXWriter {
    static func write(_ workbook: Workbook, to url: URL) throws {
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : workbook.sheets
        let names = uniqueSheetNames(sheets.map(\.name))
        var zip = ZipWriter()
        var overrides = ""
        var sheetEntries = ""
        var rels = ""

        for (index, sheet) in sheets.enumerated() {
            let number = index + 1
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetEntries += "<sheet name=\"\(XML.escape(names[index]))\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            rels += "<Relationship Id=\"rId\(number)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"

            var data = ""
            for (r, row) in sheet.rows.enumerated() {
                data += "<row r=\"\(r + 1)\">"
                for (c, cell) in row.enumerated() {
                    let ref = columnName(c) + String(r + 1)
                    switch cell {
                    case .empty: continue
                    case .string(let s):
                        data += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XML.escape(s))</t></is></c>"
                    case .number(let n):
                        data += "<c r=\"\(ref)\"><v>\(n.isFinite ? CellValue.number(n).text : "0")</v></c>"
                    case .bool(let b):
                        data += "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                    }
                }
                data += "</row>"
            }
            zip.add("xl/worksheets/sheet\(number).xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData>\(data)</sheetData></worksheet>
            """)
        }

        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\(overrides)</Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """)
        zip.add("docProps/core.xml", DOCXWriter.coreXML(title: url.deletingPathExtension().lastPathComponent))
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetEntries)</sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """)
        try zip.finish().write(to: url)
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for char in reference.uppercased() {
            guard let ascii = char.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }

    private static func uniqueSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { index, raw in
            var name = raw.replacingOccurrences(of: "[\\[\\]:*?/\\\\]", with: "-", options: .regularExpression)
            if name.isEmpty { name = "Sheet\(index + 1)" }
            name = String(name.prefix(31))
            var candidate = name
            var counter = 2
            while used.contains(candidate.lowercased()) {
                candidate = String(name.prefix(28)) + " \(counter)"
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}

enum XLSXReader {
    static func read(_ url: URL) throws -> Workbook {
        let zip = try ZipReader(url: url)
        let workbook = try XML.document(try zip.read("xl/workbook.xml"))

        var rels: [String: String] = [:]
        if let data = try? zip.read("xl/_rels/workbook.xml.rels"), let doc = try? XML.document(data) {
            for rel in doc.rootElement()?.elementChildren ?? [] {
                if let id = rel.attr("Id"), let target = rel.attr("Target") { rels[id] = target }
            }
        }

        var shared: [String] = []
        if let data = try? zip.read("xl/sharedStrings.xml"), let doc = try? XML.document(data) {
            for item in doc.rootElement()?.elementChildren.filter({ $0.tag == "si" }) ?? [] {
                // Concatenate text runs, skipping phonetic guides.
                let texts = item.descendants("t").filter { $0.parent?.tag != "rph" }
                shared.append(texts.map { $0.stringValue ?? "" }.joined())
            }
        }

        let dateStyles = readDateStyles(zip)

        var sheets: [Sheet] = []
        for sheet in workbook.rootElement()?.firstDescendant("sheets")?.elementChildren ?? [] {
            let name = sheet.attr("name") ?? "Sheet\(sheets.count + 1)"
            guard let rid = sheet.attr("id"), let target = rels[rid] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = try? zip.read((path as NSString).standardizingPath) else { continue }
            let doc = try XML.document(data)
            var rows: [[CellValue]] = []
            for row in doc.rootElement()?.firstDescendant("sheetdata")?.elementChildren.filter({ $0.tag == "row" }) ?? [] {
                let rowIndex = (Int(row.attr("r") ?? "") ?? (rows.count + 1)) - 1
                guard rowIndex < 1_000_000 else { break }
                while rows.count < rowIndex { rows.append([]) }
                var cells: [CellValue] = []
                for cell in row.elementChildren where cell.tag == "c" {
                    let column = cell.attr("r").map(XLSXWriter.columnIndex) ?? cells.count
                    guard column < 16_384 else { continue }
                    while cells.count < column { cells.append(.empty) }
                    let type = cell.attr("t")
                    let value = cell.child("v")?.stringValue
                    let style = Int(cell.attr("s") ?? "") ?? 0
                    let parsed: CellValue
                    switch type {
                    case "s":
                        parsed = (Int(value ?? "")).flatMap { $0 < shared.count ? .string(shared[$0]) : nil } ?? .empty
                    case "inlineStr":
                        parsed = .string(cell.descendants("t").map { $0.stringValue ?? "" }.joined())
                    case "str", "e":
                        parsed = value.map { .string($0) } ?? .empty
                    case "b":
                        parsed = .bool(value == "1")
                    default:
                        if let value, let number = Double(value) {
                            parsed = dateStyles.contains(style) ? .string(formatDate(serial: number)) : .number(number)
                        } else {
                            parsed = value.map { .string($0) } ?? .empty
                        }
                    }
                    cells.append(parsed)
                }
                if rows.count == rowIndex { rows.append(cells) } else if rowIndex < rows.count { rows[rowIndex] = cells }
            }
            sheets.append(Sheet(name: name, rows: rows).trimmed())
        }
        return Workbook(sheets: sheets)
    }

    /// Indices into cellXfs whose number format is a date/time.
    private static func readDateStyles(_ zip: ZipReader) -> Set<Int> {
        guard let data = try? zip.read("xl/styles.xml"), let doc = try? XML.document(data), let root = doc.rootElement() else { return [] }
        var customDateFormats = Set<Int>()
        for format in root.child("numfmts")?.elementChildren ?? [] {
            guard let id = Int(format.attr("numFmtId") ?? ""), let code = format.attr("formatCode") else { continue }
            let stripped = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).lowercased()
            if stripped.contains("y") || stripped.contains("d") || stripped.contains("h") || (stripped.contains("m") && !stripped.contains("0")) {
                customDateFormats.insert(id)
            }
        }
        let builtinDates: Set<Int> = Set(14...22).union(45...47).union(27...36).union(50...58)
        var result = Set<Int>()
        for (index, xf) in (root.child("cellxfs")?.elementChildren ?? []).enumerated() {
            let id = Int(xf.attr("numFmtId") ?? "0") ?? 0
            if builtinDates.contains(id) || customDateFormats.contains(id) { result.insert(index) }
        }
        return result
    }

    static func formatDate(serial: Double) -> String {
        // Excel's 1900 date system (with its fictional Feb 29, 1900).
        let days = serial >= 60 ? serial - 1 : serial
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 31))!
        let date = epoch.addingTimeInterval(days * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let hasTime = serial.truncatingRemainder(dividingBy: 1) > 0.00001
        formatter.dateFormat = serial < 1 ? "HH:mm:ss" : hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
