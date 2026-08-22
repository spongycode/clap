import Testing
import Foundation
@testable import ClapCore

@Suite("Text analysis")
struct TextAnalysisTests {

    // MARK: ColorParser

    @Test func parsesHexFormats() {
        #expect(ColorParser.parse("#f00") == ParsedColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorParser.parse("#ff0000") == ParsedColor(red: 1, green: 0, blue: 0, alpha: 1))
        let rgba = ColorParser.parse("#ff000080")
        #expect(rgba?.alpha ?? 0 < 0.51)
        #expect(rgba?.red == 1)
        #expect(ColorParser.parse("0xff0000")?.green == 0)
    }

    @Test func parsesRgbAndHslFunctions() {
        let rgb = ColorParser.parse("rgb(255, 0, 0)")
        #expect(rgb?.red == 1)
        #expect(rgb?.blue == 0)
        let hsl = ColorParser.parse("hsl(0, 100%, 50%)")
        #expect(hsl != nil)
    }

    @Test func hslConvertsToCorrectRgb() throws {
        // Primary hues: hsl(0,100%,50%)=red, hsl(120,...)=green, hsl(240,...)=blue.
        let red = try #require(ColorParser.parse("hsl(0, 100%, 50%)"))
        #expect(red.red == 1 && red.green == 0 && red.blue == 0)

        let green = try #require(ColorParser.parse("hsl(120, 100%, 50%)"))
        #expect(green.red == 0 && green.green == 1 && green.blue == 0)

        let blue = try #require(ColorParser.parse("hsl(240, 100%, 50%)"))
        #expect(blue.red == 0 && blue.green == 0 && blue.blue == 1)

        // White and black have zero saturation.
        let white = try #require(ColorParser.parse("hsl(0, 0%, 100%)"))
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
        let black = try #require(ColorParser.parse("hsl(0, 0%, 0%)"))
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)

        // Hue wraps: -120deg ≡ 240deg (pure blue).
        let wrapped = try #require(ColorParser.parse("hsl(-120, 100%, 50%)"))
        #expect(wrapped == blue)
    }

    @Test func rejectsNonColors() {
        #expect(ColorParser.parse("hello world") == nil)
        #expect(ColorParser.parse("#12345") == nil)
        #expect(ColorParser.parse(nil) == nil)
    }

    // MARK: CaseConverter

    @Test func convertsCaseStyles() {
        #expect(CaseConverter.convert("hello world test", to: .camelCase) == "helloWorldTest")
        #expect(CaseConverter.convert("hello world", to: .pascalCase) == "HelloWorld")
        #expect(CaseConverter.convert("HelloWorld", to: .snakeCase) == "hello_world")
        #expect(CaseConverter.convert("hello world", to: .kebabCase) == "hello-world")
        #expect(CaseConverter.convert("hello world", to: .constantCase) == "HELLO_WORLD")
    }

    // MARK: TextTransformer

    @Test func base64RoundTrip() {
        let encoded = TextTransformer.encodeBase64("clap")
        #expect(encoded == Data("clap".utf8).base64EncodedString())
        #expect(TextTransformer.decodeBase64(encoded) == "clap")
    }

    @Test func decodeBase64RejectsPlainWords() {
        #expect(TextTransformer.decodeBase64("hello") == nil)
        #expect(TextTransformer.decodeBase64("not base64!!!") == nil)
    }

    @Test func urlRoundTrip() {
        let encoded = TextTransformer.encodeURL("a b&c=d")
        #expect(TextTransformer.decodeURL(encoded) == "a b&c=d")
        #expect(TextTransformer.decodeURL("nothing to decode") == nil)
    }

    // MARK: JWTData

    @Test func parsesWellFormedJWT() throws {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = b64(#"{"sub":"user-1","iss":"clap","exp":4102444800}"#)
        let token = "\(header).\(payload).signature"

        let jwt = try #require(JWTData.parse(token))
        #expect(jwt.algorithm == "HS256")
        #expect(jwt.subject == "user-1")
        #expect(jwt.issuer == "clap")
        #expect(jwt.isExpired == false)
        #expect(jwt.payloadJSON.contains("user-1"))
    }

    @Test func rejectsNonJWT() {
        #expect(JWTData.parse("a.b.c") == nil)
        #expect(JWTData.parse("not a token") == nil)
    }

    // MARK: EpochData

    @Test func parsesSecondAndMillisecondTimestamps() throws {
        let seconds = try #require(EpochData.parse("1700000000"))
        #expect(seconds.unitDescription.contains("Seconds"))
        #expect(seconds.unixSeconds == 1_700_000_000)

        let millis = try #require(EpochData.parse("1700000000000"))
        #expect(millis.unitDescription.contains("Milliseconds"))
        #expect(millis.unixSeconds == 1_700_000_000)
    }

    @Test func rejectsOutOfRangeNumbers() {
        #expect(EpochData.parse("42") == nil)
        #expect(EpochData.parse("99999999999999999999999") == nil)
        #expect(EpochData.parse("not a number") == nil)
    }

    // MARK: TextSummaries

    @Test func singleLineCollapsesAndTruncates() {
        #expect(TextSummaries.singleLine("  a\n\nb\t c  ", maxChars: 100) == "a b c")
        let truncated = TextSummaries.singleLine(String(repeating: "x", count: 100), maxChars: 10)
        #expect(truncated.count == 11)
        #expect(truncated.hasSuffix("…"))
    }

    @Test func relativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-30), now: now) == "now")
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-14 * 86_400), now: now) == "2w")
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-60 * 86_400), now: now) == "2mo")
        #expect(TextSummaries.relativeTime(now.addingTimeInterval(-400 * 86_400), now: now) == "1y")
    }

    // MARK: ImageFormats

    @Test func mapsKnownFormatsToUTIs() {
        #expect(ImageFormats.uti(forFormat: "png") == "public.png")
        #expect(ImageFormats.uti(forFormat: "gif") == "com.compuserve.gif")
        #expect(ImageFormats.uti(forFormat: "JPEG") == "public.jpeg")
        #expect(ImageFormats.uti(forFormat: "bogus") == nil)
    }
}
