import Testing
import Foundation
import ClapCore
@testable import ClapCLIKit

@Suite("ArgParser")
struct ArgParserTests {

    private func parse(_ args: [String],
                       boolFlags: Set<String> = [],
                       valueFlags: Set<String> = []) -> ArgParser {
        ArgParser.parse(args, boolFlags: boolFlags, valueFlags: valueFlags, usage: "usage")
    }

    @Test func collectsPositionals() {
        #expect(parse(["a", "b", "c"]).positionals == ["a", "b", "c"])
    }

    @Test func recognizesBoolFlags() {
        let parsed = parse(["--json", "x"], boolFlags: ["--json"])
        #expect(parsed.has("--json"))
        #expect(parsed.positionals == ["x"])
    }

    @Test func recognizesValueFlagWithSpaceAndEquals() {
        #expect(parse(["--limit", "5"], valueFlags: ["--limit"]).value("--limit") == "5")
        #expect(parse(["--limit=7"], valueFlags: ["--limit"]).value("--limit") == "7")
    }

    @Test func negativeNumbersArePositionalsNotFlags() {
        #expect(parse(["-3"]).positionals == ["-3"])
    }

    @Test func intParsingWithMinimumAndDefaults() {
        let parsed = parse(["--offset", "4"], valueFlags: ["--offset"])
        #expect(parsed.int("--offset", default: 0, min: 0) == 4)
        #expect(parsed.int("--missing", default: 9, min: 0) == 9)
    }

    @Test func validatedIDAcceptsPositiveIntegersOnly() {
        #expect(ArgParser.validatedID("42") == 42)
        #expect(ArgParser.validatedID("0") == nil)
        #expect(ArgParser.validatedID("-5") == nil)
        #expect(ArgParser.validatedID("abc") == nil)
        #expect(ArgParser.validatedID("") == nil)
        #expect(ArgParser.validatedID(nil) == nil)
    }
}

@Suite("OutputFormatter")
struct OutputFormatterTests {

    @Test func previewFlattensAndTruncates() {
        #expect(OutputFormatter.previewText("a\nb\tc") == "a b c")
        let long = String(repeating: "x", count: 100)
        let preview = OutputFormatter.previewText(long)
        #expect(preview.count == 61) // 60 chars + ellipsis
        #expect(preview.hasSuffix("…"))
    }

    @Test func imagePreviewFormat() {
        let entry = ClipboardEntry(
            id: 1, type: .image, content: nil, imagePath: "x.png", imageFormat: "png",
            contentHash: "h", createdAt: Date(), lastUsedAt: Date(), sizeBytes: 2048,
            isPinned: false, isFavorite: false, useCount: 1, sourceApp: nil)
        #expect(OutputFormatter.preview(entry) == "[image png, 2.0 KB]")
    }

    @Test func relativeTimeMatchesCoreBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(OutputFormatter.relativeTime(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(OutputFormatter.relativeTime(now.addingTimeInterval(-7200), now: now) == "2h")
    }

    @Test func tableAlignsColumns() {
        let entry = ClipboardEntry(
            id: 7, type: .text, content: "hello", imagePath: nil, imageFormat: nil,
            contentHash: "h", createdAt: Date(), lastUsedAt: Date(), sizeBytes: 5,
            isPinned: true, isFavorite: false, useCount: 1, sourceApp: nil)
        let table = OutputFormatter.table([entry])
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("ID"))
        #expect(lines[1].contains("*"))
        #expect(lines[1].contains("hello"))
    }

    @Test func encodeJSONProducesSortedStableOutput() throws {
        struct Payload: Codable, Equatable { let b: Int; let a: Int }
        let json = try OutputFormatter.encodeJSON(Payload(b: 1, a: 2))
        #expect(json.contains("\"a\""))
        #expect(json.contains("\"b\""))
        // sortedKeys: "a" appears before "b"
        let aRange = try #require(json.range(of: "\"a\""))
        let bRange = try #require(json.range(of: "\"b\""))
        #expect(aRange.lowerBound < bRange.lowerBound)
    }
}
