/// Persist only Keychain references, including for private key material; never a password or key file payload.
public enum SFTPAuth: Codable, Sendable, Hashable {
    case password(secretRef: SecretRef)
    case privateKey(secretRef: SecretRef, passphraseRef: SecretRef?)
}
