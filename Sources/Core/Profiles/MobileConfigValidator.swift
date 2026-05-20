import Foundation

/// Validates a `.mobileconfig` XML payload against Apple's profile
/// schema. Returns a list of issues — empty means the profile is
/// well-formed and structurally complete.
///
/// Two passes:
///
/// 1. **XML well-formedness** via `XMLParser`. This catches mismatched
///    or missing brackets / tags and reports the exact line and column
///    where the parser bailed. Plist parsing alone collapses everything
///    into a single generic "Couldn't open file" error, which made it
///    impossible to tell *which* bracket the user dropped.
/// 2. **Plist + profile structure** via `PropertyListSerialization`:
///    top-level dictionary, required identity keys, per-payload identity
///    keys, duplicate-UUID detection. These checks only run when the
///    XML actually parses — otherwise the message would be misleading.
///
/// This is intentionally lightweight: it doesn't validate against the
/// per-MDM payload-type schemas; each vendor has its own and those would
/// belong in a separate validator.
public enum MobileConfigValidator {
    public static func validate(_ xml: String) -> [ValidationIssue] {
        guard let data = xml.data(using: .utf8) else {
            return [ValidationIssue(severity: .error, message: "File is not valid UTF-8.")]
        }
        let xmlIssues = xmlWellFormednessIssues(data: data)
        if !xmlIssues.isEmpty {
            return xmlIssues
        }
        return plistStructuralIssues(data: data)
    }

    // MARK: XML well-formedness

    /// Run an `XMLParser` pass purely to discover malformed XML before
    /// handing the data to the plist deserializer. Returns an empty
    /// array on a clean parse.
    private static func xmlWellFormednessIssues(data: Data) -> [ValidationIssue] {
        let parser = XMLParser(data: data)
        let collector = XMLErrorCollector()
        parser.delegate = collector
        let ok = parser.parse()
        if ok && collector.issues.isEmpty {
            return []
        }
        if collector.issues.isEmpty, let error = parser.parserError {
            return [ValidationIssue(
                severity: .error,
                message: humanReadable(error: error as NSError),
                line: parser.lineNumber,
                column: parser.columnNumber
            )]
        }
        return collector.issues
    }

    private static func humanReadable(error: NSError) -> String {
        // `XMLParser` localized messages tend to be terse ("Premature
        // end of data in tag ..."). Keep the original; the line/column
        // values carry the useful position info.
        if error.localizedDescription.isEmpty {
            return "XML is malformed (code \(error.code))."
        }
        return error.localizedDescription
    }

    /// `XMLParser` reports errors via a delegate callback. We collect
    /// each one with its line/column so the UI can render them as
    /// "Line 42, col 7 — Premature end of data".
    private final class XMLErrorCollector: NSObject, XMLParserDelegate {
        var issues: [ValidationIssue] = []

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            let nsError = parseError as NSError
            issues.append(ValidationIssue(
                severity: .error,
                message: humanReadable(error: nsError),
                line: parser.lineNumber,
                column: parser.columnNumber
            ))
        }

        func parser(_ parser: XMLParser, validationErrorOccurred validationError: any Error) {
            let nsError = validationError as NSError
            issues.append(ValidationIssue(
                severity: .warning,
                message: humanReadable(error: nsError),
                line: parser.lineNumber,
                column: parser.columnNumber
            ))
        }
    }

    // MARK: Plist + structural checks

    private static func plistStructuralIssues(data: Data) -> [ValidationIssue] {
        var format: PropertyListSerialization.PropertyListFormat = .xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
        } catch {
            return [ValidationIssue(
                severity: .error,
                message: "XML parses but isn't a valid plist: \(error.localizedDescription)"
            )]
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
        /// 1-based line number when the issue is positional (XML parse
        /// errors), `nil` for whole-file structural issues.
        public var line: Int?
        /// 1-based column number when the issue is positional.
        public var column: Int?

        public init(severity: Severity, message: String, line: Int? = nil, column: Int? = nil) {
            self.severity = severity
            self.message = message
            self.line = line
            self.column = column
        }

        public var id: String {
            "\(severity.rawValue):\(line ?? -1):\(column ?? -1):\(message)"
        }

        /// Human-friendly display string. Prefixes the line/column when
        /// available so the lint list lines up.
        public var displayMessage: String {
            if let line, line > 0 {
                if let column, column > 0 {
                    return "Line \(line), col \(column) — \(message)"
                }
                return "Line \(line) — \(message)"
            }
            return message
        }

        public enum Severity: String, Sendable, Hashable {
            case error
            case warning
        }
    }
}
