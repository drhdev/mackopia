import BackupDomain

extension RepositoryKind {
    var isIntegratedBackend: Bool { kopiaStorageType != nil }
    var kopiaStorageType: String? {
        switch self {
        case .filesystem: "filesystem";
        case .s3: "s3";
        case .webdav: "webdav";
        default: nil
        }
    }
}
