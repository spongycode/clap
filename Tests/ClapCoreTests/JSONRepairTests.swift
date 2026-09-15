import Testing
import Foundation
@testable import ClapCore

@Suite("JSON repair")
struct JSONRepairTests {

    private func repaired(_ source: String) throws -> String {
        try #require(JSONRepair.repair(source)).repaired
    }

    @Test func trailingCommas() throws {
        #expect(try repaired(#"{"a": 1,}"#) == #"{"a": 1}"#)
        #expect(try repaired("[1, 2, 3,]") == "[1, 2, 3]")
        #expect(try repaired(#"{ "a": [1,], "b": 2, }"#) == #"{ "a": [1], "b": 2 }"#)
    }

    @Test func singleQuotes() throws {
        #expect(try repaired("{'a': 'x'}") == #"{"a": "x"}"#)
        // Inner double quotes get escaped during conversion.
        #expect(try repaired("{'say': \"hi\"}") == #"{"say": "hi"}"#)
    }

    @Test func bareKeys() throws {
        #expect(try repaired("{a: 1, bb: 2}") == #"{"a": 1, "bb": 2}"#)
        #expect(try repaired("{_private$: true}") == #"{"_private$": true}"#)
    }

    @Test func pythonAndJSLiterals() throws {
        #expect(try repaired(#"{"a": True, "b": False, "c": None}"#)
                == #"{"a": true, "b": false, "c": null}"#)
        #expect(try repaired(#"{"x": undefined, "y": NaN}"#)
                == #"{"x": null, "y": null}"#)
    }

    @Test func hexNumbers() throws {
        #expect(try repaired("{\"color\": 0xFF0000}") == #"{"color": 16711680}"#)
    }

    @Test func comments() throws {
        let source = """
        {
          // line comment
          "a": 1, /* block */
          "b": 2
        }
        """
        let result = try repaired(source)
        let parsed = try #require(JSONData.parse(result))
        #expect(parsed.isTopLevelObject)
        #expect(parsed.valueCount == 2)
        #expect(!result.contains("//"))
    }

    @Test func smartQuotes() throws {
        #expect(try repaired("{“a”: “x”}") == #"{"a": "x"}"#)
    }

    @Test func bomStripped() throws {
        let withBOM = "\u{FEFF}{\"a\": 1}"
        #expect(try repaired(withBOM) == #"{"a": 1}"#)
    }

    @Test func stringsAreProtected() throws {
        // Trailing comma INSIDE a string must survive.
        let result = try repaired(#"{"msg": "keep, me}", "n": 1,}"#)
        #expect(result.contains("keep, me}"))

        // Apostrophe inside a double-quoted string: input is ALREADY valid
        // JSON, so repair correctly reports nothing to do.
        #expect(JSONRepair.repair(#"{"msg": "it's fine"}"#) == nil)
    }

    @Test func combinedNastyCase() throws {
        let source = """
        // config
        {
          'enabled': True,
          retries: 0xFF,
          tags: ['a', 'b',],
          meta: { “note”: None },
        }
        """
        let result = try repaired(source)
        let parsed = try #require(JSONData.parse(result))
        #expect(parsed.isTopLevelObject)
        #expect(parsed.valueCount == 4)
    }

    @Test func validJsonIsUntouchedAndReportsNil() {
        // Already-valid JSON: repair returns nil (nothing to do, no fixes).
        #expect(JSONRepair.repair(#"{"a": 1}"#) == nil)
    }

    @Test func unrepairableReturnsNil() {
        #expect(JSONRepair.repair("just words") == nil)
        #expect(JSONRepair.repair("{") == nil)
        #expect(JSONRepair.repair("{\"a\": }") == nil)   // missing value
    }

    @Test func fixesAreReported() throws {
        let result = try #require(JSONRepair.repair("{'a': True,}"))
        #expect(result.fixes.contains("normalized single-quoted strings"))
        #expect(result.fixes.contains("converted Python/JS literals"))
        #expect(result.fixes.contains("removed trailing commas"))
    }
}

@Test func trailingCommaInPrettyMultiline() throws {
    let source = """
    {
      "name": "John",
      "age": 30,
      "active": true,
    }
    """
    let result = try #require(JSONRepair.repair(source))
    let parsed = try #require(JSONData.parse(result.repaired))
    #expect(parsed.valueCount == 3)
}

@Test func lenientPlatformParseStillOffersRepair() {
    // macOS 26 JSONSerialization accepts trailing commas, so parse succeeds —
    // but repair must STILL be able to normalize the document.
    let source = """
    {
      "name": "John",
      "age": 30,
      "active": true,
    }
    """
    let result = JSONRepair.repair(source)
    #expect(result != nil)
    #expect(JSONData.parse(result?.repaired ?? "") != nil)
}
