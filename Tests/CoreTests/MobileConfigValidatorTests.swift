import Foundation
import Testing
@testable import Core

@Suite("MobileConfig validator")
struct MobileConfigValidatorTests {
    @Test("accepts a well-formed minimal Configuration profile")
    func validMinimalProfile() {
        let xml = minimalProfile()
        let issues = MobileConfigValidator.validate(xml)
        #expect(issues.isEmpty, "Expected no issues, got: \(issues.map(\.message))")
    }

    @Test("flags missing required top-level keys")
    func missingRequiredKeys() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadType</key>
            <string>Configuration</string>
        </dict>
        </plist>
        """
        let issues = MobileConfigValidator.validate(xml)
        #expect(issues.contains { $0.message.contains("PayloadIdentifier") })
        #expect(issues.contains { $0.message.contains("PayloadUUID") })
        #expect(issues.contains { $0.message.contains("PayloadVersion") })
        #expect(issues.contains { $0.message.contains("PayloadDisplayName") })
    }

    @Test("flags duplicate PayloadUUID inside PayloadContent")
    func duplicatePayloadUUID() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadIdentifier</key><string>com.example.profile</string>
            <key>PayloadUUID</key><string>4F3F8E7C-7A24-4F0E-92E1-0F0E0C0B0A09</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadDisplayName</key><string>Test</string>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadType</key><string>com.apple.test</string>
                    <key>PayloadIdentifier</key><string>com.example.payload</string>
                    <key>PayloadUUID</key><string>00000000-0000-0000-0000-000000000001</string>
                    <key>PayloadVersion</key><integer>1</integer>
                </dict>
                <dict>
                    <key>PayloadType</key><string>com.apple.test</string>
                    <key>PayloadIdentifier</key><string>com.example.payload2</string>
                    <key>PayloadUUID</key><string>00000000-0000-0000-0000-000000000001</string>
                    <key>PayloadVersion</key><integer>1</integer>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let issues = MobileConfigValidator.validate(xml)
        #expect(issues.contains { $0.message.contains("duplicate PayloadUUID") })
    }

    @Test("flags non-XML input as an error")
    func nonXMLInput() {
        let issues = MobileConfigValidator.validate("not xml at all")
        #expect(issues.contains { $0.severity == .error })
    }

    @Test("multiple dropped brackets are all reported, not just the first")
    func reportsAllDroppedBrackets() {
        // Three separate lines with the leading `<` removed —
        // XMLParser alone stops at the first one, but the heuristic
        // scanner finds the rest so the user sees every breakage.
        let broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadType</key>
            <string>Configuration</string>
            key>PayloadIdentifier</key>
            <string>com.example.profile</string>
            key>PayloadUUID</key>
            <string>4F3F8E7C-7A24-4F0E-92E1-0F0E0C0B0A09</string>
            key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
        let issues = MobileConfigValidator.validate(broken)
        let positionalErrors = issues.filter { $0.severity == .error && $0.line != nil }
        // At minimum: the three dropped-bracket lines (7, 9, 11) all
        // surface as separate issues. XMLParser may add its own
        // entry on top of those; we don't pin the exact count.
        let lines = Set(positionalErrors.compactMap(\.line))
        #expect(lines.contains(7))
        #expect(lines.contains(9))
        #expect(lines.contains(11))
    }

    @Test("XML parse errors carry a line number from XMLParser")
    func xmlErrorsHaveLineNumbers() {
        // Two unclosed tags — XMLParser should report the position
        // where it gave up parsing.
        let broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>PayloadType
            <string>Configuration</string>
        </dict>
        </plist>
        """
        let issues = MobileConfigValidator.validate(broken)
        let xmlError = issues.first { $0.severity == .error && $0.line != nil }
        #expect(xmlError != nil)
        #expect((xmlError?.line ?? 0) > 0)
        if let xmlError {
            #expect(xmlError.displayMessage.hasPrefix("Line "))
        }
    }

    private func minimalProfile() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadIdentifier</key>
            <string>com.example.profile</string>
            <key>PayloadUUID</key>
            <string>4F3F8E7C-7A24-4F0E-92E1-0F0E0C0B0A09</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadDisplayName</key>
            <string>Test Profile</string>
        </dict>
        </plist>
        """
    }
}
