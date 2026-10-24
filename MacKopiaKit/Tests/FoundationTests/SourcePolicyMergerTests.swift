import BackupDomain
import Foundation
import KopiaServer
import Testing

@testable import BackupEngine

struct SourcePolicyMergerTests {
    private func desired(ignore: [String] = [], maxFileSize: Int64? = nil) throws -> TranslatedSourcePolicy {
        TranslatedSourcePolicy(
            source: try BackupSource(
                path: "/Synthetic Private Source",
                volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false)),
            retention: try RetentionPolicy(keepLatest: 0, keepDaily: 7), compression: .none,
            ignore: ignore, ignoreCacheDirs: false, maxFileSize: maxFileSize, oneFileSystem: false)
    }

    private func object(_ document: KopiaPolicyDocument) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
    }

    @Test func preservesUnknownNestedValuesAndExactNumberTokens() throws {
        let input = Data(
            #"{"future":{"number":9007199254740993,"huge":184467440737095516160,"negative":-184467440737095516160,"decimal":1.234567890123456789,"null":null,"a":[false,"private"]},"retention":{"keepLatest":8,"keepHourly":6,"ignoreIdenticalSnapshots":false,"future":{"x":1}},"files":{"ignoreDotFiles":[".custom"],"noParentDotFiles":true,"future":[null]},"compression":{"minSize":11,"neverCompress":[".zip"],"future":true},"noParent":false,"scheduling":{"intervalSeconds":3600}}"#
                .utf8)
        let merged = try SourcePolicyMerger.merge(
            desired(ignore: ["*.tmp", "!keep.tmp", "*.tmp"]), into: KopiaPolicyDocument(data: input))
        let encoded = try merged.encoded()
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""number":9007199254740993"#))
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""decimal":1.234567890123456789"#))
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""huge":184467440737095516160"#))
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""negative":-184467440737095516160"#))
        let root = try object(merged)
        let retention = try #require(root["retention"] as? [String: Any])
        #expect(retention["keepLatest"] as? Int == 0)
        #expect(retention["keepHourly"] == nil)
        #expect(retention["keepDaily"] as? Int == 7)
        #expect(retention["ignoreIdenticalSnapshots"] as? Bool == false)
        #expect(retention["future"] != nil)
        let files = try #require(root["files"] as? [String: Any])
        #expect(files["ignore"] as? [String] == ["*.tmp", "!keep.tmp", "*.tmp"])
        #expect(files["ignoreDotFiles"] as? [String] == [".custom"])
        #expect(files["noParentDotFiles"] as? Bool == true)
        #expect(files["ignoreCacheDirs"] as? Bool == false)
        let compression = try #require(root["compression"] as? [String: Any])
        #expect(compression["compressorName"] as? String == "none")
        #expect(compression["minSize"] as? Int == 11)
        #expect(compression["neverCompress"] as? [String] == [".zip"])
        #expect((root["scheduling"] as? [String: Any])?["intervalSeconds"] as? Int == 3600)
        #expect(root["noParent"] as? Bool == false)
    }

    @Test func emptyAndZeroAreLocalValuesWithoutClaimingEffectiveOverrides() throws {
        let merged = try SourcePolicyMerger.merge(desired(maxFileSize: 0), into: KopiaPolicyDocument())
        let root = try object(merged)
        let files = try #require(root["files"] as? [String: Any])
        #expect(files["ignore"] as? [String] == [])
        #expect(files["noParentIgnore"] as? Bool == true)
        #expect(files["maxFileSize"] as? Int == 0)
        #expect(root["noParent"] == nil)
        #expect(root["scheduling"] == nil)
        // Kopia 0.23.1's mergeStringList and mergeInt64 still inherit these empty/zero values.
        let withoutLimit = try SourcePolicyMerger.merge(desired(), into: merged)
        #expect((try object(withoutLimit)["files"] as? [String: Any])?["maxFileSize"] == nil)
    }

    @Test func idempotentIncludingRoundTripAndPrivateReflection() throws {
        let desired = try desired(ignore: ["private pattern"])
        let original = try KopiaPolicyDocument(data: Data(#"{"files":null,"retention":null,"future":null}"#.utf8))
        let first = try SourcePolicyMerger.merge(desired, into: original)
        #expect(try SourcePolicyMerger.merge(desired, into: first) == first)
        let roundTrip = try KopiaPolicyDocument(data: first.encoded())
        #expect(try SourcePolicyMerger.merge(desired, into: roundTrip) == first)
        #expect(!String(reflecting: first).contains("private pattern"))
        #expect(!String(reflecting: first).contains("Synthetic Private Source"))
        #expect((try object(first))["future"] is NSNull)
    }

    @Test(arguments: ["[]", "null", "1", "{", #"{"files":1}"#, #"{"files":{"a":1,"a":2}}"#, #"{"a":1,"a":2}"#])
    func rejectsMalformedOrAmbiguousManagedObjects(input: String) throws {
        #expect(throws: KopiaPolicyMergeError.invalidDocument) {
            try SourcePolicyMerger.merge(desired(), into: KopiaPolicyDocument(data: Data(input.utf8)))
        }
    }

    @Test func rejectsResourceLimitsAndDoesNotLeakInputInErrors() throws {
        for input in [
            Data(repeating: 32, count: KopiaPolicyDocument.maximumBytes + 1),
            Data(
                ("{\"private\":" + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}")
                    .utf8),
        ] {
            #expect(throws: KopiaPolicyMergeError.invalidDocument) { try KopiaPolicyDocument(data: input) }
        }
        #expect(!KopiaPolicyMergeError.invalidDocument.debugDescription.contains("private"))
    }
}
