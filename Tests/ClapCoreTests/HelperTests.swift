import Foundation
import Testing
@testable import ClapCore

@Suite("TextNormalizer")
struct TextNormalizerTests {
    @Test func trimsLeadingAndTrailingWhitespaceAndNewlines() {
        #expect(TextNormalizer.normalize("  hello  ") == "hello")
        #expect(TextNormalizer.normalize("\n\thello\r\n") == "hello")
        #expect(TextNormalizer.normalize("hello") == "hello")
    }

    @Test func preservesInteriorWhitespace() {
        #expect(TextNormalizer.normalize("  a  b\n\nc  ") == "a  b\n\nc")
    }

    @Test func whitespaceOnlyBecomesEmpty() {
        #expect(TextNormalizer.normalize("  \n\t \r\n ") == "")
        #expect(TextNormalizer.normalize("") == "")
    }
}

@Suite("ContentHasher")
struct ContentHasherTests {
    @Test func fnv1a64KnownVectors() {
        // Official FNV-1a 64-bit test vectors.
        #expect(ContentHasher.textHash("") == "cbf29ce484222325")
        #expect(ContentHasher.textHash("a") == "af63dc4c8601ec8c")
        #expect(ContentHasher.textHash("foobar") == "85944171f73967e8")
    }

    @Test func fnv1a64Stability() {
        let h1 = ContentHasher.textHash("clipboard content")
        let h2 = ContentHasher.textHash("clipboard content")
        #expect(h1 == h2)
        #expect(h1.count == 16)
        #expect(h1 == h1.lowercased())
        #expect(ContentHasher.textHash("clipboard content!") != h1)
    }

    @Test func sha256KnownVector() {
        let abc = Data("abc".utf8)
        #expect(ContentHasher.imageHash(abc)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHasher.imageHash(abc).count == 64)
    }
}

@Suite("ByteSize")
struct ByteSizeTests {
    @Test func parsePlainNumbers() {
        #expect(ByteSize.parse("1024") == 1024)
        #expect(ByteSize.parse("0") == 0)
    }

    @Test func parseUnits() {
        #expect(ByteSize.parse("50MB") == 52_428_800)
        #expect(ByteSize.parse("1.5GB") == 1_610_612_736)
        #expect(ByteSize.parse("100kb") == 102_400)
        #expect(ByteSize.parse("1gb") == 1_073_741_824)
        #expect(ByteSize.parse("2K") == 2048)     // optional B
        #expect(ByteSize.parse("10 MB") == 10_485_760)
        #expect(ByteSize.parse("512b") == 512)
    }

    @Test func parseRejectsGarbage() {
        #expect(ByteSize.parse("") == nil)
        #expect(ByteSize.parse("MB") == nil)
        #expect(ByteSize.parse("abc") == nil)
        #expect(ByteSize.parse("-5MB") == nil)
        #expect(ByteSize.parse("12XB") == nil)
    }

    @Test func formatStyles() {
        #expect(ByteSize.format(0) == "0 B")
        #expect(ByteSize.format(512) == "512 B")
        #expect(ByteSize.format(1024) == "1.0 KB")
        #expect(ByteSize.format(19_083_674) == "18.2 MB")
        #expect(ByteSize.format(52_428_800) == "50.0 MB")
        #expect(ByteSize.format(1_610_612_736) == "1.5 GB")
    }

    @Test func parseFormatRoundTripStaysClose() throws {
        let parsed = try #require(ByteSize.parse("18.2MB"))
        #expect(ByteSize.format(parsed) == "18.2 MB")
    }
}

@Suite("SafeRegex")
struct SafeRegexTests {
    @Test func compilesValidPattern() throws {
        let regex = try SafeRegex.compile("^h.llo$")
        #expect(SafeRegex.matches(regex, in: "hello"))
        #expect(!SafeRegex.matches(regex, in: "goodbye"))
    }

    @Test func invalidPatternThrowsInvalidPattern() {
        #expect { try SafeRegex.compile("[unclosed") } throws: { error in
            guard case ClapCoreError.invalidPattern = error else { return false }
            return true
        }
    }

    @Test func overlongPatternRejected() {
        let long = String(repeating: "a", count: 1001)
        #expect { try SafeRegex.compile(long) } throws: { error in
            guard case ClapCoreError.invalidPattern = error else { return false }
            return true
        }
    }

    @Test func matchingIsBoundedToInputSlice() throws {
        let regex = try SafeRegex.compile("needle$")
        let huge = String(repeating: "x", count: 20_000) + "needle"
        // The needle is beyond the 10k slice, so it must not match.
        #expect(!SafeRegex.matches(regex, in: huge))
    }

    @Test func matchingIsCaseInsensitiveByDefault() throws {
        let regex = try SafeRegex.compile("get.*extra")
        #expect(SafeRegex.matches(regex, in: "intent.getParcelableExtra"))
        #expect(SafeRegex.matches(regex, in: "GET /extra HTTP/1.1"))
    }

    @Test func inlineFlagRestoresCaseSensitivity() throws {
        let regex = try SafeRegex.compile("(?-i)get.*extra")
        #expect(!SafeRegex.matches(regex, in: "intent.getParcelableExtra"))
        #expect(SafeRegex.matches(regex, in: "intent.getparcelableextra"))
    }
}

@Suite("ShellHistoryParser")
struct ShellHistoryParserTests {
    @Test func unmetafyReversesZshEscaping() {
        // In zsh metafication, 0x83 followed by (byte ^ 0x20) represents the byte.
        // For example, byte 0x83 itself is represented as 0x83, 0xA3 (0x83 ^ 0x20 = 0xA3).
        let input = Data([0x68, 0x69, 0x83, 0xA3, 0x21])
        let output = ShellHistoryParser.unmetafy(input)
        #expect(output == Data([0x68, 0x69, 0x83, 0x21]))
    }

    @Test func unmetafyLeavesUnescapedDataUnchanged() {
        let input = Data("hello world".utf8)
        #expect(ShellHistoryParser.unmetafy(input) == input)
    }

    @Test func parseExtendedHistoryLines() {
        let raw = """
        : 1723710000:0;git status
        : 1723710050:2;git commit -m "feat"
        """
        let commands = ShellHistoryParser.parse(Data(raw.utf8))
        #expect(commands.count == 2)
        #expect(commands[0].text == "git status")
        #expect(commands[0].executedAt == Date(timeIntervalSince1970: 1_723_710_000))
        #expect(commands[1].text == "git commit -m \"feat\"")
        #expect(commands[1].executedAt == Date(timeIntervalSince1970: 1_723_710_050))
    }

    @Test func parsePlainBashHistoryLines() {
        let raw = """
        ls -la
        cd /tmp
        cargo build
        """
        let commands = ShellHistoryParser.parse(Data(raw.utf8))
        #expect(commands.count == 3)
        #expect(commands.map(\.text) == ["ls -la", "cd /tmp", "cargo build"])
        #expect(commands.allSatisfy { $0.executedAt == nil })
    }

    @Test func parseMultilineContinuations() {
        let raw = """
        : 1723710100:0;docker run \\
          -it \\
          alpine sh
        : 1723710200:0;echo done
        """
        let commands = ShellHistoryParser.parse(Data(raw.utf8))
        #expect(commands.count == 2)
        #expect(commands[0].text == "docker run \n  -it \n  alpine sh")
        #expect(commands[0].executedAt == Date(timeIntervalSince1970: 1_723_710_100))
        #expect(commands[1].text == "echo done")
    }

    @Test func parseSkipsEmptyLines() {
        let raw = "\n  \n\n: 1723710000:0;ls\n\n"
        let commands = ShellHistoryParser.parse(Data(raw.utf8))
        #expect(commands.count == 1)
        #expect(commands[0].text == "ls")
    }
}
