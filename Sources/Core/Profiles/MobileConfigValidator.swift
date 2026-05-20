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
    public static func validate(
        _ xml: String,
        schema: PayloadSchema? = nil
    ) -> [ValidationIssue] {
        guard let data = xml.data(using: .utf8) else {
            return [ValidationIssue(severity: .error, message: "File is not valid UTF-8.")]
        }
        // XMLParser stops at the first malformed character, so it
        // only sees one error per parse even when the user dropped
        // brackets on three different lines. We supplement its
        // positional report with a heuristic line scanner that finds
        // the common "missing leading `<`" pattern across the whole
        // file, then merge — XMLParser's exact column wins for the
        // line they overlap on; the scanner surfaces the rest.
        let xmlIssues = xmlWellFormednessIssues(data: data)
        let heuristics = bracketHeuristicIssues(xml: xml)
        let xmlLines = Set(xmlIssues.compactMap { $0.line })
        var combined = xmlIssues
        combined.append(contentsOf: heuristics.filter { issue in
            guard let line = issue.line else { return true }
            return !xmlLines.contains(line)
        })
        if !combined.isEmpty {
            return combined.sorted { ($0.line ?? Int.max) < ($1.line ?? Int.max) }
        }
        var structural = plistStructuralIssues(data: data)
        if let schema {
            structural.append(contentsOf: schemaIssues(data: data, schema: schema))
        }
        return structural
    }

    // MARK: Schema-driven warnings

    /// Walk every payload in `PayloadContent` and flag deprecated
    /// properties against the catalogue vendored from
    /// ninxsoft/LowProfile. Unknown PayloadTypes degrade silently —
    /// the YAML only catalogues Apple-defined payloads, and vendor
    /// payloads (`com.example.mdm.foo`) routinely have keys we have
    /// no way to model.
    private static func schemaIssues(data: Data, schema: PayloadSchema) -> [ValidationIssue] {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              let payloads = dict["PayloadContent"] as? [[String: Any]] else {
            return []
        }
        var issues: [ValidationIssue] = []
        for (index, payload) in payloads.enumerated() {
            guard let payloadType = payload["PayloadType"] as? String,
                  let definition = schema.definition(for: payloadType) else { continue }
            let index2 = definition.propertyIndex
            for key in payload.keys {
                if let property = index2[key], property.deprecated {
                    issues.append(ValidationIssue(
                        severity: .warning,
                        message: "PayloadContent[\(index)]: \"\(key)\" is deprecated for \(payloadType)."
                    ))
                }
            }
        }
        return issues
    }

    // MARK: Bracket heuristics

    /// Scan each non-comment, non-CDATA line for the textbook missing
    /// bracket patterns:
    ///   - a leading `tag>` with no `<` (e.g. `key>foo</key>` instead of
    ///     `<key>foo</key>`)
    ///   - a closing tag fragment (`</tag` or `tag/>`) with no `>`
    ///     terminating it
    ///   - an opening tag fragment (`<tag` followed by content but no
    ///     `>` on the same line, ignoring single-line comments and
    ///     multi-line wrappers)
    ///
    /// The scanner is intentionally conservative — it would rather
    /// miss an obscure breakage than emit false positives on
    /// well-formed multi-line constructs. Comments are tracked across
    /// lines so a `<!-- ... -->` block doesn't trigger noise.
    private static func bracketHeuristicIssues(xml: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var inComment = false
        let lines = xml.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Track multi-line comments so a `<!-- ... -->` block
            // doesn't trip the per-line bracket counts.
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if line.contains("<!--") && !line.contains("-->") {
                inComment = true
                continue
            }
            // Single-line comments — skip entirely.
            if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { continue }
            // XML prolog and DOCTYPE — skip.
            if trimmed.hasPrefix("<?") || trimmed.hasPrefix("<!DOCTYPE") { continue }

            // Pattern A: "tagname>..." at the start of the line with
            // no leading "<". Captures the dropped opening bracket
            // the user just made.
            if let match = leadingTagPattern.firstMatch(
                in: line,
                options: [],
                range: NSRange(line.startIndex..., in: line)
            ), let tagRange = Range(match.range(at: 1), in: line) {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Missing opening '<' before \"\(line[tagRange])>\".",
                    line: lineNumber,
                    column: 1
                ))
                continue
            }

            // Pattern B: bracket count mismatch on a non-comment line
            // — usually a missing trailing `>` on an opening tag.
            // Counts `<` and `>` literally because property-list
            // content doesn't contain stray brackets in well-formed
            // mobileconfigs.
            let opens = line.filter { $0 == "<" }.count
            let closes = line.filter { $0 == ">" }.count
            if opens != closes {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Bracket mismatch: \(opens) '<' but \(closes) '>' on this line.",
                    line: lineNumber
                ))
            }
        }
        return issues
    }

    /// Matches `tagname>` (or `tagname/>`) at the very start of a line
    /// (with optional leading whitespace) when there's no preceding
    /// `<`. The captured group is the tag name itself.
    private static let leadingTagPattern: NSRegularExpression = {
        // ^\s*([A-Za-z][\w:-]*)>  — anchored, no `<` before the tag.
        try! NSRegularExpression(
            pattern: #"^\s*([A-Za-z][\w:-]*)/?>"#,
            options: []
        )
    }()

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
