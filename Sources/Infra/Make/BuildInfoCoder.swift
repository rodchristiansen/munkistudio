import Foundation
import Yams
import Core

/// Round-trips a munkipkg `BuildInfo` through plist / JSON / YAML. The
/// YAML path uses Yams' `Codable` coders directly, matching the Swift
/// `munkipkg` fork — `BuildInfo`'s own `Codable` decides which keys
/// land on disk.
enum BuildInfoCoder {
    static func decode(data: Data, format: BuildInfoFormat) throws -> BuildInfo {
        switch format {
        case .plist:
            return try PropertyListDecoder().decode(BuildInfo.self, from: data)
        case .json:
            return try JSONDecoder().decode(BuildInfo.self, from: data)
        case .yaml:
            let yaml = String(decoding: data, as: UTF8.self)
            return try YAMLDecoder().decode(BuildInfo.self, from: yaml)
        }
    }

    static func encode(_ buildInfo: BuildInfo, format: BuildInfoFormat) throws -> Data {
        switch format {
        case .plist:
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            return try encoder.encode(buildInfo)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            return try encoder.encode(buildInfo)
        case .yaml:
            let encoder = YAMLEncoder()
            encoder.options.allowUnicode = true
            let yaml = try encoder.encode(buildInfo)
            return Data(yaml.utf8)
        }
    }
}
