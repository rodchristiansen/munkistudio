import Foundation
import Core
import Security

/// Probes a `.mobileconfig` file for a PKCS#7 signing envelope using
/// Apple's `Security` framework. No third-party ASN.1 dependency
/// needed — `CMSDecoder` ships with macOS and handles every signed
/// `.mobileconfig` the system itself can install.
///
/// Detection is best-effort: if `CMSDecoder` can't decode the
/// content as a CMS message we return `.unsigned`. Profiles in the
/// wild come in three shapes — XML, PKCS#7-wrapped XML, or other —
/// and only the second produces a non-empty signer list.
public enum ProfileSignatureDetector {
    public static func detect(data: Data) -> ProfileSignature {
        // Fast path: a file that starts with the XML prolog is
        // certainly not a PKCS#7 envelope. Skip the heavier
        // CMSDecoder dance.
        if data.starts(with: Data("<?xml".utf8)) || data.starts(with: Data("<!DOCTYPE".utf8)) {
            return .unsigned
        }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            return .unsigned
        }

        let updateResult = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, bytes.count)
        }
        guard updateResult == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            return .unsigned
        }

        var numSigners: Int = 0
        guard CMSDecoderGetNumSigners(decoder, &numSigners) == errSecSuccess,
              numSigners > 0 else {
            return .unsigned
        }

        // Pull every certificate the envelope carries — typically the
        // leaf + any intermediates Apple bundles for chain validation.
        var certsRef: CFArray?
        guard CMSDecoderCopyAllCerts(decoder, &certsRef) == errSecSuccess,
              let certs = certsRef as? [SecCertificate], !certs.isEmpty else {
            return .signed(signers: [])
        }

        let parsed = certs.map(parseCertificate)
        return .signed(signers: parsed)
    }

    /// Extract the human-readable bits from a SecCertificate. CN is
    /// often the only field worth showing in a tight chip; the
    /// subject summary is the fallback Apple uses internally.
    private static func parseCertificate(_ certificate: SecCertificate) -> SigningCertificate {
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown"
        var commonNameRef: CFString?
        let result = SecCertificateCopyCommonName(certificate, &commonNameRef)
        let cn = (result == errSecSuccess) ? (commonNameRef as String?) : nil
        return SigningCertificate(commonName: cn, summary: summary)
    }
}
