import XCTest
@testable import OrbitKit

final class FormatTests: XCTestCase {
    func testDetectsMultiPartExtensions() {
        XCTAssertEqual(FormatDetector.format(for: URL(fileURLWithPath: "/tmp/backup.tar.gz")), .tgz)
        XCTAssertEqual(FormatDetector.format(for: URL(fileURLWithPath: "/tmp/notes.gz")), .gzip)
        XCTAssertEqual(FormatDetector.format(for: URL(fileURLWithPath: "/tmp/Photo.JPEG")), .jpg)
        XCTAssertEqual(FormatDetector.format(for: URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")), .heic)
        XCTAssertNil(FormatDetector.format(for: URL(fileURLWithPath: "/tmp/unknown.xyz")))
    }

    func testDetectsFolders() {
        XCTAssertEqual(FormatDetector.format(for: FileManager.default.temporaryDirectory), .folder)
    }

    func testDetectsFromUTI() {
        XCTAssertEqual(FormatDetector.format(forUTI: "public.jpeg"), .jpg)
        XCTAssertEqual(FormatDetector.format(forUTI: "com.adobe.pdf"), .pdf)
    }
}

final class OutputNamingTests: XCTestCase {
    func testSplitKeepsMultiPartExtension() {
        XCTAssertEqual(OutputNaming.split("Report.final.tar.gz").base, "Report.final")
        XCTAssertEqual(OutputNaming.split("Report.final.tar.gz").ext, "tar.gz")
        XCTAssertEqual(OutputNaming.split("photo.jpg").base, "photo")
    }

    func testUniqueURLIncrements() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(OutputNaming.uniqueURL(in: dir, fileName: "a.tar.gz").lastPathComponent, "a.tar.gz")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.tar.gz").path, contents: Data())
        XCTAssertEqual(OutputNaming.uniqueURL(in: dir, fileName: "a.tar.gz").lastPathComponent, "a 2.tar.gz")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a 2.tar.gz").path, contents: Data())
        XCTAssertEqual(OutputNaming.uniqueURL(in: dir, fileName: "a.tar.gz").lastPathComponent, "a 3.tar.gz")
    }
}

final class CatalogTests: XCTestCase {
    let bare = Capabilities(ffmpeg: nil, cwebp: nil, libreOffice: nil, iwork: IWork(pages: false, keynote: false, numbers: false),
                            imageIOWritableTypes: ["public.jpeg", "public.png"])

    func titles(_ nodes: [MenuNode]) -> [String] { nodes.map(\.title) }

    func testImageTargetsExcludeSource() {
        let menu = Catalog.convertMenu(for: FileSelection(urls: [URL(fileURLWithPath: "/x/a.jpg")]), capabilities: bare)
        XCTAssertFalse(titles(menu).contains("JPG"))
        XCTAssertTrue(titles(menu).contains("PNG"))
        XCTAssertNotNil(menu.first { $0.title == "WebP" }?.disabledReason, "WebP needs an encoder")
    }

    func testMixedImagesOfferEitherFormat() {
        let selection = FileSelection(urls: [URL(fileURLWithPath: "/x/a.jpg"), URL(fileURLWithPath: "/x/b.png")])
        let names = titles(Catalog.convertMenu(for: selection, capabilities: bare))
        XCTAssertTrue(names.contains("JPG"))
        XCTAssertTrue(names.contains("PNG"))
    }

    func testVideoGroupsAudioTargets() {
        let menu = Catalog.convertMenu(for: FileSelection(urls: [URL(fileURLWithPath: "/x/a.mov")]), capabilities: bare)
        let audio = menu.first { $0.id == "convert.audio" }
        XCTAssertEqual(audio?.children.first?.title, "MP3")
        XCTAssertEqual(menu.first { $0.title == "MP4" }?.disabledReason, "Needs FFmpeg")
    }

    func testPagesNeedsPages() {
        let menu = Catalog.convertMenu(for: FileSelection(urls: [URL(fileURLWithPath: "/x/a.docx")]), capabilities: bare)
        XCTAssertEqual(menu.first { $0.title == "Pages" }?.disabledReason, "Requires Pages")
    }

    func testMergeOnlyForMultiple() {
        let one = Catalog.toolsMenu(for: FileSelection(urls: [URL(fileURLWithPath: "/x/a.pdf")]), capabilities: bare)
        let two = Catalog.toolsMenu(for: FileSelection(urls: [URL(fileURLWithPath: "/x/a.pdf"), URL(fileURLWithPath: "/x/b.pdf")]), capabilities: bare)
        XCTAssertFalse(titles(one).contains("Merge"))
        XCTAssertTrue(titles(two).contains("Merge"))
        XCTAssertEqual(titles(one).last, "ZIP")
    }

    func testResolvedPicksFirstEnabledChild() {
        let menu = Catalog.toolsMenu(for: FileSelection(urls: [URL(fileURLWithPath: "/x/a.jpg")]), capabilities: bare)
        let compress = menu.first { $0.title == "Compress" }
        XCTAssertEqual(compress?.resolved?.payload, .operation(.tool(.imageCompress, "light")))
    }
}

final class MarkdownTests: XCTestCase {
    func testInlineStyles() {
        let spans = MarkdownReader.inline("Hello **bold** and *it* with `code` and [link](https://x.y) snake_case")
        XCTAssertTrue(spans.contains { $0.text == "bold" && $0.bold })
        XCTAssertTrue(spans.contains { $0.text == "it" && $0.italic })
        XCTAssertTrue(spans.contains { $0.text == "code" && $0.code })
        XCTAssertTrue(spans.contains { $0.text == "link" && $0.link == "https://x.y" })
        XCTAssertTrue(spans.plainText.hasSuffix("snake_case"))
    }

    func testBlocks() {
        let doc = MarkdownReader.read("# Title\n\nPara one\ncontinues.\n\n- a\n  - b\n1. c\n\n| A | B |\n|---|---|\n| 1 | 2 |\n", baseURL: nil)
        guard doc.blocks.count == 6 else { return XCTFail("got \(doc.blocks)") }
        if case .heading(1, let s) = doc.blocks[0] { XCTAssertEqual(s.plainText, "Title") } else { XCTFail() }
        if case .paragraph(let s) = doc.blocks[1] { XCTAssertEqual(s.plainText, "Para one continues.") } else { XCTFail() }
        if case .listItem(false, 1, _) = doc.blocks[3] {} else { XCTFail("nested item") }
        if case .listItem(true, 0, _) = doc.blocks[4] {} else { XCTFail("ordered item") }
        if case .table(let rows) = doc.blocks[5] { XCTAssertEqual(rows.count, 2) } else { XCTFail() }
    }

    func testRoundTrip() {
        let source = "# Title\n\nSome **bold** text.\n\n- one\n- two\n"
        let written = MarkdownWriter.write(MarkdownReader.read(source, baseURL: nil))
        XCTAssertEqual(written, source)
    }
}

final class ContainerTests: XCTestCase {
    func testZipRoundTrip() throws {
        var writer = ZipWriter()
        let big = String(repeating: "orbit ", count: 1000)
        writer.add("mimetype", "application/epub+zip", compress: false)
        writer.add("dir/big.txt", big)
        let reader = try ZipReader(data: writer.finish())
        XCTAssertEqual(reader.entries.map(\.path), ["mimetype", "dir/big.txt"])
        XCTAssertEqual(try reader.readString("dir/big.txt"), big)
        XCTAssertEqual(try reader.readString("mimetype"), "application/epub+zip")
    }

    func testXLSXRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = Workbook(sheets: [Sheet(name: "Data", rows: [[.string("name"), .string("qty")], [.string("A & B"), .number(3.5)]])])
        try XLSXWriter.write(book, to: url)
        let read = try XLSXReader.read(url)
        XCTAssertEqual(read.sheets.first?.name, "Data")
        XCTAssertEqual(read.sheets.first?.rows, book.sheets[0].rows)
    }

    func testDOCXRoundTripKeepsStructure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = RichDocument(blocks: [
            .heading(level: 2, spans: [Span("Heading")]),
            .paragraph([Span("Plain "), Span("bold", bold: true)]),
            .listItem(ordered: true, level: 0, spans: [Span("first")]),
        ])
        try DOCXWriter.write(doc, to: url)
        let read = try DOCXReader.read(url)
        if case .heading(2, let s) = read.blocks[0] { XCTAssertEqual(s.plainText, "Heading") } else { XCTFail("\(read.blocks)") }
        if case .paragraph(let s) = read.blocks[1] { XCTAssertTrue(s.contains { $0.bold && $0.text == "bold" }) } else { XCTFail() }
        if case .listItem(true, 0, _) = read.blocks[2] {} else { XCTFail() }
    }

    func testCSVQuotingAndDelimiters() {
        XCTAssertEqual(CSV.parse("a,\"b, c\",\"d \"\"q\"\"\"\n1,2,3\n"), [["a", "b, c", "d \"q\""], ["1", "2", "3"]])
        XCTAssertEqual(CSV.detectDelimiter("a;b;c\n1;2;3\n"), ";")
        XCTAssertEqual(CSV.write([[.string("x,y"), .number(2)]], delimiter: ","), "\"x,y\",2\n")
    }
}

final class TimingTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Timecode.parseDuration("1:30"), 90)
        XCTAssertEqual(Timecode.parseDuration("2m"), 120)
        XCTAssertEqual(Timecode.parseDuration("1h20m"), 4800)
        XCTAssertEqual(Timecode.parseDuration("45"), 45)
        XCTAssertEqual(Timecode.parseDuration("00:00:01.500"), 1.5)
        XCTAssertNil(Timecode.parseDuration("soon"))
    }

    func testSubtitleRoundTrip() {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n01:00:03,000 --> 01:00:04,000\n<i>World</i>\n"
        let cues = SubtitleConverter.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].start, 3603)
        XCTAssertEqual(SubtitleConverter.parse(SubtitleConverter.vtt(cues)), cues)
        XCTAssertEqual(SubtitleConverter.plainText(cues), "Hello\nWorld\n")
    }

    func testPDFRanges() throws {
        XCTAssertEqual(try PDFTools.parseRanges("1-3, 5, 7-", pageCount: 9), [1...3, 5...5, 7...9])
        XCTAssertThrowsError(try PDFTools.parseRanges("4-2", pageCount: 9))
    }

    func testResizeParsing() throws {
        XCTAssertEqual(try ImageTools.targetSize(option: "50", text: nil, width: 400, height: 200).0, 200)
        XCTAssertEqual(try ImageTools.targetSize(option: "custom", text: "100w", width: 400, height: 200).1, 50)
        XCTAssertEqual(try ImageTools.targetSize(option: "custom", text: "200x200", width: 400, height: 200).0, 200)
    }

    func testMediaInfoParsing() {
        let text = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'vt.mp4':
          Duration: 00:01:03.50, start: 0.000000, bitrate: 3686 kb/s
          Stream #0:0[0x1](und): Video: h264 (Main) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 1280x720 [SAR 1:1 DAR 16:9], 3550 kb/s, 29.97 fps, 30 tbr
          Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 129 kb/s (default)
        """
        let info = MediaInfo.parse(text)
        XCTAssertEqual(info.duration, 63.5)
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.width, 1280)
        XCTAssertEqual(info.height, 720)
        XCTAssertEqual(info.fps, 29.97)
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.audioChannels, 2)
    }
}
