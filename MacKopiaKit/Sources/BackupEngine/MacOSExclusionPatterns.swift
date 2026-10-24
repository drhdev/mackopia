import BackupDomain
import Foundation

/// Versioned lexical rules only. The caller supplies the home of the backed-up user;
/// neither filesystem access nor symlink/volume identity verification happens here.
package enum MacOSExclusionPatterns {
    package static let version = 1

    private static let homeDirectories = [
        "Library/Caches", "Library/Logs", "Library/Containers/*/Data/Library/Caches",
        "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches",
        "Library/Mobile Documents", "Library/CloudStorage",
    ]

    package static func resolve(for source: BackupSource, homeDirectory: String) throws -> [String] {
        guard DomainValidation.absolutePath(homeDirectory),
            !homeDirectory.contains(where: { $0.isNewline })
        else { throw DomainValidationError.invalidPath }

        let sourceComponents = source.path.split(separator: "/").map(String.init)
        let homeComponents = homeDirectory.split(separator: "/").map(String.init)
        var patterns = [".Trash/", ".DS_Store", ".Spotlight-V100/", ".fseventsd/"]
        for directory in homeDirectories {
            let relative = directory.split(separator: "/").map(String.init)
            let target = homeComponents + relative
            let sharedCount = min(sourceComponents.count, target.count)
            // Only the fixed Containers component is a glob; characters in real paths are literal.
            guard
                (0..<sharedCount).allSatisfy({ index in
                    let wildcard = index >= homeComponents.count && target[index] == "*"
                    return wildcard || sourceComponents[index] == target[index]
                })
            else { continue }

            if sourceComponents.count >= target.count {
                // Kopia 0.23.1: ** excludes every entry when the source itself is an excluded subtree.
                return ["**"]
            }
            let suffix = target.indices.dropFirst(sourceComponents.count).map { index in
                index >= homeComponents.count && target[index] == "*" ? "*" : escaped(target[index])
            }
            // Kopia 0.23.1: a leading slash anchors a rule to this source, avoiding nested Library lookalikes.
            patterns.append("/" + suffix.joined(separator: "/") + "/")
        }
        patterns += [".cache/", "*.tmp", "*.swp"]
        // Generated paths have the same bounded, single-line representation as stored user patterns.
        return try ExcludeRules(
            useMacOSDefaults: false, honorTimeMachineExclusions: false,
            ignoreCacheDirs: false, patterns: patterns
        ).patterns
    }

    private static func escaped(_ component: String) -> String {
        component.reduce(into: "") { result, character in
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
