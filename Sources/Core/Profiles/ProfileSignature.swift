import Foundation

/// Result of probing a `.mobileconfig` file for a PKCS#7 / CMS
/// signing envelope. Apple-deployed profiles are wrapped in this
/// envelope before installation; the inner XML carries the actual
/// payload while the outer ASN.1 structure carries the signing
/// certificate chain so the OS can verify provenance.
///
/// Most repos hold *unsigned* XML — signing is a deployment-time
/// step. We still detect signed files so the editor can show the
/// signer rather than treating the binary blob as malformed XML.
public enum ProfileSignature: Sendable, Hashable {
    case unsigned
    /// PKCS#7-signed envelope. `signers` lists the certificates
    /// found in the envelope, ordered by the parser's natural
    /// traversal (typically leaf → root).
    case signed(signers: [SigningCertificate])

    public var isSigned: Bool {
        if case .signed = self { return true }
        return false
    }

    /// Convenience for the header chip — pulls the first signer's
    /// display name when signed, `nil` otherwise.
    public var signerSummary: String? {
        if case .signed(let signers) = self, let first = signers.first {
            return first.commonName ?? first.summary
        }
        return nil
    }
}

/// Lightweight view of a `SecCertificate` shaped for display.
/// We extract just the fields the UI surfaces today — common name
/// plus the OS-supplied subject summary. The full certificate
/// data can be re-derived from disk if a deeper inspector lands
/// later.
public struct SigningCertificate: Sendable, Hashable {
    /// The certificate's Common Name (CN), if present. Pulled out
    /// because it's the most useful single string for a chip
    /// (e.g. "Developer ID Application: Acme Corp (TEAMID)").
    public var commonName: String?
    /// Apple's `SecCertificateCopySubjectSummary` output —
    /// usually the CN, but falls back to other DN components when
    /// the certificate lacks one.
    public var summary: String

    public init(commonName: String? = nil, summary: String) {
        self.commonName = commonName
        self.summary = summary
    }
}
