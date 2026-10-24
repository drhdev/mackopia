import Foundation
import KopiaServer
import Testing

struct KopiaPolicyDocumentComparisonTests {
    @Test func canonicalComparisonKeepsExactOpaqueNumbersAndArrayOrder() throws {
        let left = try KopiaPolicyDocument(
            data: Data(#"{"future":{"b":184467440737095516160,"a":["ü",{"x":1}]}}"#.utf8))
        let reordered = try KopiaPolicyDocument(
            data: Data(#"{ "future": { "a": ["\u00fc",{"x":1}], "b":184467440737095516160 } }"#.utf8))
        #expect(try left.equivalent(to: reordered))
        let different = try KopiaPolicyDocument(
            data: Data(#"{"future":{"b":184467440737095516161,"a":["ü",{"x":1}]}}"#.utf8))
        #expect(try !left.equivalent(to: different))
        let reversed = try KopiaPolicyDocument(
            data: Data(#"{"future":{"b":184467440737095516160,"a":[{"x":1},"ü"]}}"#.utf8))
        #expect(try !left.equivalent(to: reversed))
    }

    @Test func onlyKnownGoOmissionsAreEquivalentAndOptionalFalseStaysSignificant() throws {
        let proposed = try KopiaPolicyDocument(
            data: Data(#"{"files":{"ignore":[],"maxFileSize":0,"ignoreCacheDirs":false,"oneFileSystem":false}}"#.utf8))
        let stored = try KopiaPolicyDocument(
            data: Data(
                #"{"retention":{},"files":{"ignoreCacheDirs":false,"oneFileSystem":false},"errorHandling":{},"scheduling":{},"compression":{},"metadataCompression":{},"splitter":{},"actions":{},"upload":{},"osSnapshots":{"volumeShadowCopy":{}},"logging":{"directories":{},"entries":{}}}"#
                    .utf8))
        #expect(try proposed.equivalentStoredDefinition(to: stored))
        #expect(try !proposed.equivalent(to: stored))
        #expect(try !proposed.equivalentStoredDefinition(to: KopiaPolicyDocument()))
        let unknown = try KopiaPolicyDocument(data: Data(#"{"future":{}}"#.utf8))
        #expect(try !unknown.equivalentStoredDefinition(to: KopiaPolicyDocument()))
    }

    @Test(arguments: [#"{"scheduling":{"manual":true,"manual":false}}"#, #"{"scheduling":[]}"#])
    func rejectsAmbiguousSchedulingDefinitions(input: String) {
        #expect(throws: KopiaPolicyMergeError.invalidDocument) { try KopiaPolicyDocument(data: Data(input.utf8)) }
    }
}
