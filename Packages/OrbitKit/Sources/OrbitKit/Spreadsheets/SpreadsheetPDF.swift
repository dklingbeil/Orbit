import AppKit

/// Renders sheets as paginated grids (used when no office app is available, and for CSV/TSV).
enum SpreadsheetPDF {
    static func write(_ workbook: Workbook, to url: URL) throws {
        let sheets = workbook.sheets.filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw OrbitError.failed("Nothing to print.") }

        let baseFont = NSFont(name: "Helvetica", size: 8.5) ?? .systemFont(ofSize: 8.5)
        let boldFont = NSFont(name: "Helvetica-Bold", size: 8.5) ?? .boldSystemFont(ofSize: 8.5)
        let margin: CGFloat = 36
        let portrait = PageGeometry.pageSize

        var mediaBox = CGRect(origin: .zero, size: portrait)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw OrbitError.failed("Couldn't create \(url.lastPathComponent).")
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }

        for sheet in sheets {
            let columns = sheet.columnCount
            guard columns > 0 else { continue }

            // Natural column widths, capped so one long cell doesn't eat the page.
            var widths = Array(repeating: CGFloat(24), count: columns)
            for (r, row) in sheet.rows.prefix(500).enumerated() {
                for (c, cell) in row.enumerated() {
                    let font = r == 0 ? boldFont : baseFont
                    let w = (cell.text as NSString).size(withAttributes: [.font: font]).width + 10
                    widths[c] = min(200, max(widths[c], w))
                }
            }
            let natural = widths.reduce(0, +)
            let landscape = natural > portrait.width - margin * 2
            let pageSize = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
            let available = pageSize.width - margin * 2
            let scale = min(1, max(0.35, available / natural))
            widths = widths.map { $0 * scale }
            let font = NSFont(descriptor: baseFont.fontDescriptor, size: 8.5 * scale) ?? baseFont
            let headerFont = NSFont(descriptor: boldFont.fontDescriptor, size: 8.5 * scale) ?? boldFont
            let rowHeight = 14 * scale
            let titleHeight: CGFloat = sheets.count > 1 ? 22 : 0
            let rowsPerPage = max(1, Int((pageSize.height - margin * 2 - titleHeight) / rowHeight))

            let header = sheet.rows.first ?? []
            let body = Array(sheet.rows.dropFirst())
            var start = 0
            var firstPage = true
            repeat {
                var box = CGRect(origin: .zero, size: pageSize)
                context.beginPage(mediaBox: &box)
                context.saveGState()
                context.translateBy(x: 0, y: pageSize.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

                var y = margin
                if titleHeight > 0 {
                    let title = firstPage ? sheet.name : "\(sheet.name) (continued)"
                    (title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: NSFont(name: "Helvetica-Bold", size: 12) ?? boldFont])
                    y += titleHeight
                }
                let pageRows = Array(body[start..<min(body.count, start + rowsPerPage - 1)])
                let printed = [header] + pageRows
                for (index, row) in printed.enumerated() {
                    var x = margin
                    if index == 0 {
                        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
                        context.fill(CGRect(x: margin, y: y, width: widths.reduce(0, +), height: rowHeight))
                    }
                    for c in 0..<columns {
                        let cell = CGRect(x: x, y: y, width: widths[c], height: rowHeight)
                        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
                        context.setLineWidth(0.4)
                        context.stroke(cell)
                        if c < row.count {
                            let value = row[c]
                            let paragraph = NSMutableParagraphStyle()
                            paragraph.lineBreakMode = .byTruncatingTail
                            if case .number = value { paragraph.alignment = .right }
                            (value.text as NSString).draw(in: cell.insetBy(dx: 3, dy: 1.5 * scale), withAttributes: [
                                .font: index == 0 ? headerFont : font, .paragraphStyle: paragraph, .foregroundColor: NSColor.black,
                            ])
                        }
                        x += widths[c]
                    }
                    y += rowHeight
                }
                context.restoreGState()
                context.endPage()
                start += max(1, rowsPerPage - 1)
                firstPage = false
            } while start < body.count
        }
        context.closePDF()
    }
}
