import Foundation

/// Validates a `.mobileconfig` XML payload against Apple's profile
/// schema. Returns a list of issues — empty means the profile is
/// well-formed and structurally complete.
///
/// This is intentionally lightweight: parses as a plist, checks that
/// the top-level dictionary is a `Configuration` profile, and verifies
/// the required identity keys and per-payload identity keys. It does
/// not validate against MDM payload-type schemas (each MDM vendor has
/// its own); those would belong in a separate validator.
public enum MobileConfigValidator {
    public static func validate(_ xml: String) -> [ValidationIssue] {
        guard let data = xml.data(using: .utf8) else {
            return [ValidationIssue(severity: .error, message: "File is not valid UTF-8.")]
        }
        var format: PropertyListSerialization.PropertyListFormat = .xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
        } catch {
            return [ValidationIssue(severity: .error, message: "XML doesn't parse as a plist: \(error.localizedDescription)")]
        }
        guard let dict = object as? [String: Any] else {
            return [ValidationIssue(severity: .error, message: "Top-level value must be a dictionary.")]
        }
        var issues: [ValidationIssue] = []
        if format != .xml {
            issues.append(ValidationIssue(
                severity: .warning,
                message: "Profile is encoded as a binary plist. Convention is XML for .mobileconfig — saving from here will re-emit XML."
            ))
        }
        if (dict["PayloadType"] as? String) != "Configuration" {
            issues.append(ValidationIssue(
                severity: .error,
                message: "Top-level PayloadType must be \"Configuration\"."
            ))
        }
        for key in ["PayloadIdentifier", "PayloadUUID", "PayloadVersion", "PayloadDisplayName"] {
            if dict[key] == nil {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Missing required top-level key \(key)."
                ))
            }
        }
        if let uuid = dict["PayloadUUID"] as? String, UUID(uuidString: uuid) == nil {
            issues.append(ValidationIssue(severity: .warning, message: "PayloadUUID is not a valid UUID string."))
        }
        if let version = dict["PayloadVersion"] as? Int, version != 1 {
            issues.append(ValidationIssue(
                severity: .warning,
                message: "PayloadVersion is \(version); Apple expects 1 for the outer profile."
            ))
        }
        let payloadContentAny = dict["PayloadContent"]
        if let payloads = payloadContentAny as? [[String: Any]] {
            var seenIdentifiers: Set<String> = []
            var seenUUIDs: Set<String> = []
            for (index, payload) in payloads.enumerated() {
                let location = "PayloadContent[\(index)]"
                for key in ["PayloadType", "PayloadIdentifier", "PayloadUUID", "PayloadVersion"] {
                    if payload[key] == nil {
                        issues.append(ValidationIssue(
                            severity: .error,
                            message: "\(location): missing required key \(key)."
                        ))
                    }
                }
                if let identifier = payload["PayloadIdentifier"] as? String {
                    if !seenIdentifiers.insert(identifier).inserted {
                        issues.append(ValidationIssue(
                            severity: .warning,
                            message: "\(location): duplicate PayloadIdentifier \"\(identifier)\"."
                        ))
                    }
                }
                if let uuid = payload["PayloadUUID"] as? String {
                    if !seenUUIDs.insert(uuid).inserted {
                        issues.append(ValidationIssue(
                            severity: .warning,
                            message: "\(location): duplicate PayloadUUID \"\(uuid)\"."
                        ))
                    }
                    if UUID(uuidString: uuid) == nil {
                        issues.append(ValidationIssue(
                            severity: .warning,
                            message: "\(location): PayloadUUID is not a valid UUID string."
                        ))
                    }
                }
            }
        } else if payloadContentAny != nil {
            issues.append(ValidationIssue(
                severity: .error,
                message: "PayloadContent must be an array of dictionaries."
            ))
        }
        return issues
    }

    public struct ValidationIssue: Sendable, Hashable, Identifiable {
        public var severity: Severity
        public var message: String

        public var id: String { "\(severity.rawValue):\(message)" }

        public enum Severity: String, Sendable, Hashable {
            case error
            case warning
        }
    }
}
