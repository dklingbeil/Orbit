import Foundation

enum ODSWriter {
    static func write(_ workbook: Workbook, to url: URL) throws {
        var tables = ""
        for (index, sheet) in workbook.sheets.enumerated() {
            let name = sheet.name.isEmpty ? "Sheet\(index + 1)" : sheet.name
            tables += "<table:table table:name=\"\(XML.escape(name))\"><table:table-column table:number-columns-repeated=\"\(max(1, sheet.columnCount))\"/>"
            for row in sheet.rows {
                tables += "<table:table-row>"
                if row.isEmpty { tables += "<table:table-cell/>" }
                for cell in row {
                    switch cell {
                    case .empty:
                        tables += "<table:table-cell/>"
                    case .string(let s):
                        let paragraphs = s.components(separatedBy: "\n").map { "<text:p>\(XML.escape($0))</text:p>" }.joined()
                        tables += "<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    case .number(let n):
                        let text = CellValue.number(n).text
                        tables += "<table:table-cell office:value-type=\"float\" office:value=\"\(text)\"><text:p>\(text)</text:p></table:table-cell>"
                    case .bool(let b):
                        tables += "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"\(b)\"><text:p>\(b ? "TRUE" : "FALSE")</text:p></table:table-cell>"
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }

        var zip = ZipWriter()
        zip.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", compress: false)
        zip.add("META-INF/manifest.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """)
        zip.add("content.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """)
        try zip.finish().write(to: url)
    }
}

enum ODSReader {
    static func read(_ url: URL) throws -> Workbook {
        let zip = try ZipReader(url: url)
        let document = try XML.document(try zip.read("content.xml"))
        guard let spreadsheet = document.rootElement()?.firstDescendant("spreadsheet") else {
            throw OrbitError.invalidInput("The ODS file has no spreadsheet.")
        }
        var sheets: [Sheet] = []
        for table in spreadsheet.elementChildren where table.tag == "table" {
            var rows: [[CellValue]] = []
            for row in table.descendants("table-row") {
                var cells: [CellValue] = []
                for cell in row.elementChildren where cell.tag == "table-cell" || cell.tag == "covered-table-cell" {
                    let value = parse(cell)
                    let repeats = min(Int(cell.attr("number-columns-repeated") ?? "1") ?? 1, 1024)
                    // Huge repeats are padding to the sheet's edge; keep one if empty.
                    let count = value.isEmpty && repeats > 64 ? 1 : repeats
                    cells += Array(repeating: value, count: count)
                }
                let repeats = Int(row.attr("number-rows-repeated") ?? "1") ?? 1
                let isEmpty = cells.allSatisfy(\.isEmpty)
                rows += Array(repeating: cells, count: isEmpty && repeats > 64 ? 1 : min(repeats, 10_000))
            }
            sheets.append(Sheet(name: table.attr("name") ?? "Sheet\(sheets.count + 1)", rows: rows).trimmed())
        }
        return Workbook(sheets: sheets)
    }

    private static func parse(_ cell: XMLElement) -> CellValue {
        let text = cell.elementChildren.filter { $0.tag == "p" }.map { $0.stringValue ?? "" }.joined(separator: "\n")
        switch cell.attr("value-type") {
        case "float", "percentage", "currency":
            if let value = cell.attr("value").flatMap(Double.init) { return .number(value) }
            return text.isEmpty ? .empty : .string(text)
        case "boolean":
            return .bool(cell.attr("boolean-value") == "true")
        case "date":
            return .string(cell.attr("date-value") ?? text)
        case "time":
            return .string(text.isEmpty ? cell.attr("time-value") ?? "" : text)
        default:
            return text.isEmpty ? .empty : .string(text)
        }
    }
}
