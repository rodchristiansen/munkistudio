import Foundation

/// Embedded copy of the user's MainProfileTemplate.mobileconfig — kept
/// in source so new-profile creation never depends on the network and
/// CI builds reproducibly. The original lives at
/// https://github.com/rodchristiansen/mobileconfig-profiles and should
/// be re-synced into this constant if it changes upstream.
///
/// Placeholders the substitution layer rewrites at `create()` time:
///   - `PROFILE_NAME` — the user-chosen profile name (sanitized for
///     identifier use).
///   - `GENERATED_UUID_01` / `_02` / `_03` — distinct fresh UUIDs per
///     placeholder, with all occurrences of the same placeholder
///     mapped to the same generated UUID so the identifier suffixes
///     keep matching their corresponding PayloadUUID.
///
/// Everything else (the `com.example.profiles` prefix, the inner
/// `PayloadType`s and example keys) stays verbatim — that's the
/// teaching surface the user fills in after creation.
enum MainProfileTemplate {
    static let xml: String = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!--
\tMainProfileTemplate.mobileconfig

\tA teaching template for building macOS configuration profiles.
\tEach key is annotated to explain its purpose.

\tQuick start:
\t  1. Copy this file and rename it (e.g. MyAppPrefs.mobileconfig).
\t  2. Replace all UPPERCASE placeholders with real values.
\t  3. Generate fresh UUIDs:  uuidgen  (run in Terminal for each one).
\t  4. Set PayloadType in each inner dict to the preference domain you
\t     want to manage (e.g. com.apple.Safari, com.google.Chrome).
\t  5. Validate:  plutil -lint MyAppPrefs.mobileconfig
\t  6. Install for testing:  sudo profiles install -path MyAppPrefs.mobileconfig
\t  7. Remove:  sudo profiles remove -identifier com.example.profiles.MyAppPrefs

\tPayloadType reference:
\t  - Direct domain: target the app's preference domain directly
\t    (e.g. com.apple.Safari, com.microsoft.Word)
\t  - com.apple.ManagedClient.preferences: MCX-style wrapping for domains
\t    that require Forced/Set-Once management (less common on modern macOS)
\t  - com.apple.TCC.configuration-profile-policy: Privacy/PPPC permissions
\t  - com.apple.extensiblesso: Single Sign-On extensions
\t  - com.apple.system-extension-policy: System extension allow-listing
\t  - com.apple.servicemanagement: Background task / login item management
\t  - com.apple.notificationsettings: Notification center management

\tTools:
\t  - iMazing Profile Editor (free): https://imazing.com/profile-editor
\t  - Apple Configurator 2 (Mac App Store)
\t  - profiledocs.com - Apple profile payload reference
-->
<dict>
\t<key>PayloadContent</key>
\t<!-- Inner payload array: each dict targets one preference domain or policy -->
\t<array>
\t\t<dict>
\t\t\t<key>PayloadDisplayName</key>
\t\t\t<!-- Human-readable name shown inside the profile detail pane -->
\t\t\t<string>PAYLOAD_DISPLAY_NAME</string>
\t\t\t<key>PayloadIdentifier</key>
\t\t\t<!-- Convention: profile identifier + UUID suffix -->
\t\t\t<string>com.example.profiles.PROFILE_NAME.GENERATED_UUID_02</string>
\t\t\t<key>PayloadType</key>
\t\t\t<!-- The preference domain to manage (reverse-domain notation) -->
\t\t\t<string>com.example.app.domain</string>
\t\t\t<key>PayloadUUID</key>
\t\t\t<!-- Generate with: uuidgen -->
\t\t\t<string>GENERATED_UUID_02</string>
\t\t\t<key>PayloadVersion</key>
\t\t\t<integer>1</integer>

\t\t\t<!-- Your managed preference keys go here -->
\t\t\t<key>SETTING_KEY_BOOL</key>
\t\t\t<true/>
\t\t\t<key>SETTING_KEY_STRING</key>
\t\t\t<string>value</string>
\t\t\t<key>SETTING_KEY_INT</key>
\t\t\t<integer>1</integer>
\t\t</dict>

\t\t<!-- Example: Privacy Preferences Policy Control (TCC/PPPC) payload -->
\t\t<!-- Grants apps access to protected resources without user prompts -->
\t\t<dict>
\t\t\t<key>PayloadDisplayName</key>
\t\t\t<string>Privacy Preferences Policy Control</string>
\t\t\t<key>PayloadIdentifier</key>
\t\t\t<string>com.example.profiles.PROFILE_NAME.GENERATED_UUID_03</string>
\t\t\t<key>PayloadType</key>
\t\t\t<string>com.apple.TCC.configuration-profile-policy</string>
\t\t\t<key>PayloadUUID</key>
\t\t\t<string>GENERATED_UUID_03</string>
\t\t\t<key>PayloadVersion</key>
\t\t\t<integer>1</integer>
\t\t\t<key>Services</key>
\t\t\t<dict>
\t\t\t\t<!-- Available service keys include:
\t\t\t\t     Accessibility, AppleEvents, BluetoothAlways,
\t\t\t\t     MediaLibrary, Photos, PostEvent, ScreenCapture,
\t\t\t\t     SystemPolicyAllFiles, SystemPolicyAppBundles,
\t\t\t\t     SystemPolicyDesktopFolder, SystemPolicyDocumentsFolder,
\t\t\t\t     SystemPolicyDownloadsFolder, SystemPolicyNetworkVolumes,
\t\t\t\t     SystemPolicyRemovableVolumes -->
\t\t\t\t<key>SystemPolicyAllFiles</key>
\t\t\t\t<array>
\t\t\t\t\t<dict>
\t\t\t\t\t\t<key>Allowed</key>
\t\t\t\t\t\t<true/>
\t\t\t\t\t\t<key>CodeRequirement</key>
\t\t\t\t\t\t<!-- Get with: codesign -dr - /path/to/app -->
\t\t\t\t\t\t<string>identifier "com.example.app" and anchor apple generic</string>
\t\t\t\t\t\t<key>Comment</key>
\t\t\t\t\t\t<string>Allow ExampleApp full disk access</string>
\t\t\t\t\t\t<key>Identifier</key>
\t\t\t\t\t\t<string>com.example.app</string>
\t\t\t\t\t\t<key>IdentifierType</key>
\t\t\t\t\t\t<!-- bundleID or path -->
\t\t\t\t\t\t<string>bundleID</string>
\t\t\t\t\t</dict>
\t\t\t\t</array>
\t\t\t</dict>
\t\t</dict>
\t</array>
\t<key>PayloadDisplayName</key>
\t<!-- Profile name shown in System Settings > Profiles -->
\t<string>PROFILE_NAME</string>
\t<key>PayloadIdentifier</key>
\t<!-- Unique reverse-domain identifier for your profile -->
\t<!-- Convention: com.yourorg.profiles.ProfileName -->
\t<string>com.example.profiles.PROFILE_NAME</string>
\t<key>PayloadOrganization</key>
\t<string>ExampleOrganization</string>
\t<key>PayloadRemovalDisallowed</key>
\t<!-- true = requires admin password to remove -->
\t<true/>
\t<key>PayloadScope</key>
\t<!-- System = device-level, User = user-level -->
\t<string>System</string>
\t<key>PayloadType</key>
\t<!-- Always "Configuration" for the outer wrapper -->
\t<string>Configuration</string>
\t<key>PayloadUUID</key>
\t<!-- Generate with: uuidgen -->
\t<string>GENERATED_UUID_01</string>
\t<key>PayloadVersion</key>
\t<integer>1</integer>
</dict>
</plist>
"""

    /// Render the template for a new profile with `name` substituted
    /// into the `PROFILE_NAME` placeholder and a fresh UUID generated
    /// per `GENERATED_UUID_NN` placeholder. Distinct placeholders get
    /// distinct UUIDs; multiple occurrences of the same placeholder
    /// share a UUID (so a payload's identifier suffix keeps matching
    /// its own PayloadUUID).
    static func rendered(forName name: String) -> String {
        var xml = xml
        xml = xml.replacingOccurrences(of: "PROFILE_NAME", with: sanitizeForIdentifier(name))
        let placeholders = ["GENERATED_UUID_01", "GENERATED_UUID_02", "GENERATED_UUID_03"]
        for placeholder in placeholders {
            xml = xml.replacingOccurrences(of: placeholder, with: UUID().uuidString)
        }
        return xml
    }

    /// Strip slashes and non-alphanumeric characters from `name` so it
    /// can drop into a reverse-DNS identifier without breaking the
    /// resulting string. Slashes become dots so nested profile names
    /// (`wifi/staff`) keep their hierarchy in the identifier
    /// (`com.example.profiles.wifi.staff`).
    static func sanitizeForIdentifier(_ name: String) -> String {
        let dotted = name.replacingOccurrences(of: "/", with: ".")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let filtered = dotted.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(filtered))
        return result.isEmpty ? "Profile" : result
    }
}
