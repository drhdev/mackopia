import Foundation
import Testing

@testable import KopiaServer

@Test func policyDTOsReadRecordedDefinitionsInheritanceAndOrigins() throws {
    let decoder = JSONDecoder()
    let policy = try decoder.decode(KopiaPolicy.self, from: fixture("rest-policy"))
    #expect(policy.retention?.keepLatest == 10)
    #expect(policy.retention?.keepAnnual == 0)
    #expect(policy.retention?.keepDaily == nil)
    #expect(policy.files?.ignore == ["*.tmp"])
    #expect(policy.files?.ignoreDotFiles == nil)
    let resolved = try decoder.decode(KopiaResolvedPolicy.self, from: fixture("rest-policy-resolved"))
    #expect(resolved.defined?.retention?.keepDaily == nil)
    #expect(resolved.effective?.retention?.keepDaily == 7)
    #expect(resolved.effective?.retention?.keepAnnual == 0)
    #expect(resolved.effective?.retention?.ignoreIdenticalSnapshots == false)
    #expect(resolved.effective?.files?.ignoreDotFiles == [".kopiaignore"])
    #expect(resolved.effective?.compression?.compressorName == "zstd")
    #expect(resolved.definition?.retention?["keepAnnual"]?.path == "/fixture/source")
    #expect(resolved.definition?.retention?["keepDaily"]?.path == "")
    #expect(resolved.definition?.compression?["compressorName"]?.userName == "test-user")
    for value in [
        String(reflecting: resolved), String(reflecting: resolved.definition), String(reflecting: policy.files),
    ] {
        #expect(!value.contains("/fixture/source"))
        #expect(!value.contains("test-user"))
        #expect(!value.contains("*.tmp"))
    }
}

@Test func policyDTOsPreserveUnknownFieldsNilZeroAndFalseWithoutDefaults() throws {
    let decoder = JSONDecoder()
    let empty = try decoder.decode(KopiaPolicy.self, from: Data("{}".utf8))
    #expect(empty.retention == nil)
    #expect(empty.files == nil)
    let missing = try decoder.decode(KopiaResolvedPolicy.self, from: Data("{}".utf8))
    #expect(missing.effective == nil)
    #expect(missing.defined == nil)
    let value = try decoder.decode(
        KopiaPolicy.self,
        from: Data(
            #"{"retention":{"keepDaily":0},"files":{"ignoreCacheDirs":false,"oneFileSystem":false,"maxFileSize":5000000000},"compression":{"compressorName":"future"},"future":42}"#
                .utf8))
    #expect(value.retention?.keepDaily == 0)
    #expect(value.retention?.keepLatest == nil)
    #expect(value.files?.ignoreCacheDirs == false)
    #expect(value.files?.oneFileSystem == false)
    #expect(value.files?.maxFileSize == 5_000_000_000)
    #expect(value.compression?.compressorName == "future")
    for json in [
        #"{"retention":{"keepDaily":"invalid"}}"#, #"{"files":{"ignore":{}}}"#, #"{"files":{"oneFileSystem":0}}"#,
    ] {
        #expect(throws: DecodingError.self) { try decoder.decode(KopiaPolicy.self, from: Data(json.utf8)) }
    }
    let error = try #require(JSONSerialization.jsonObject(with: fixture("rest-policy-missing")) as? [String: String])
    #expect(error["code"] == "NOT_FOUND")
}
