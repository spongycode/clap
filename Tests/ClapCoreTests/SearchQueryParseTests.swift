import Foundation
import Testing
@testable import ClapCore

@Suite("SearchQuery.parse")
struct SearchQueryParseTests {
    @Test func bareTerms() {
        let q = SearchQuery.parse("hello world", limit: 50, offset: 10)
        #expect(q.text == "hello world")
        #expect(q.regex == nil)
        #expect(q.type == nil)
        #expect(q.limit == 50)
        #expect(q.offset == 10)
        #expect(q.pinnedOnly == false)
    }

    @Test func quotedPhrasePreserved() {
        let q = SearchQuery.parse("foo \"exact phrase\" bar", limit: 100, offset: 0)
        #expect(q.text == "foo \"exact phrase\" bar")
    }

    @Test func typeFilter() {
        #expect(SearchQuery.parse("cat type:image", limit: 100, offset: 0).type == .image)
        #expect(SearchQuery.parse("type:text cat", limit: 100, offset: 0).type == .text)
        let q = SearchQuery.parse("cat type:image", limit: 100, offset: 0)
        #expect(q.text == "cat")
    }

    @Test func unknownTypeValueIgnored() {
        let q = SearchQuery.parse("cat type:video", limit: 100, offset: 0)
        #expect(q.type == nil)
        #expect(q.text == "cat")
    }

    @Test func regexToken() {
        let q = SearchQuery.parse("regex:^foo.*bar$", limit: 100, offset: 0)
        #expect(q.regex == "^foo.*bar$")
        #expect(q.text == nil)
    }

    @Test func regexAsOnlyFilterTakesRemainderOfString() {
        // Pattern with a space, regex: is the only filter.
        let q = SearchQuery.parse("regex:foo bar", limit: 100, offset: 0)
        #expect(q.regex == "foo bar")
        #expect(q.text == nil)
    }

    @Test func regexWithTypeFilterUsesTokenOnly() {
        let q = SearchQuery.parse("type:text regex:abc", limit: 100, offset: 0)
        #expect(q.regex == "abc")
        #expect(q.type == .text)
        #expect(q.text == nil)
    }

    @Test func regexWinsOverText() {
        let q = SearchQuery.parse("hello regex:abc", limit: 100, offset: 0)
        #expect(q.regex == "abc")
        #expect(q.text == nil) // text ignored when regex present
    }

    @Test func emptyString() {
        let q = SearchQuery.parse("", limit: 100, offset: 0)
        #expect(q.text == nil)
        #expect(q.regex == nil)
        #expect(q.type == nil)
    }
}

@Suite("QueryTokenizer")
struct QueryTokenizerTests {
    @Test func splitsOnWhitespaceRespectingQuotes() {
        let tokens = QueryTokenizer.tokenize("a \"b c\"  d")
        #expect(tokens == [
            .init(value: "a", quoted: false),
            .init(value: "b c", quoted: true),
            .init(value: "d", quoted: false),
        ])
    }

    @Test func unterminatedQuoteBecomesPhrase() {
        let tokens = QueryTokenizer.tokenize("x \"tail end")
        #expect(tokens == [
            .init(value: "x", quoted: false),
            .init(value: "tail end", quoted: true),
        ])
    }
}

@Suite("FTS match expression")
struct FTSExpressionTests {
    @Test func bareTermsBecomePrefixMatches() {
        let tokens = QueryTokenizer.tokenize("hello wor")
        #expect(ClipboardStore.ftsMatchExpression(tokens) == "\"hello\"* \"wor\"*")
    }

    @Test func phrasesStayPhrases() {
        let tokens = QueryTokenizer.tokenize("\"exact phrase\" term")
        #expect(ClipboardStore.ftsMatchExpression(tokens) == "\"exact phrase\" \"term\"*")
    }

    @Test func doubleQuotesEscaped() {
        let tokens = [QueryTokenizer.Token(value: "say \"hi\"", quoted: true)]
        #expect(ClipboardStore.ftsMatchExpression(tokens) == "\"say \"\"hi\"\"\"")
    }
}
