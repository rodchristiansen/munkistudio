import Foundation
import Core
import Infra

/// Builds a `TestEnvironment` from the user's Testing settings. The
/// view layer holds the only place that knows how to translate settings
/// into a concrete environment — Core and Infra stay free of UI-tier
/// configuration plumbing.
enum TestEnvironmentFactory {

    enum FactoryError: Error, LocalizedError {
        case tartUnavailable
        case missingBaseImage

        var errorDescription: String? {
            switch self {
            case .tartUnavailable:
                return "Tart isn't installed or isn't on PATH. Install Tart (https://tart.run) and try again."
            case .missingBaseImage:
                return "No Tart base image configured — set one in Settings → Features → Testing."
            }
        }
    }

    /// Resolved snapshot of testing settings — `Sendable` so the
    /// factory can run on a background actor without dragging in the
    /// `@Observable` `AppSettings` itself.
    struct Configuration: Sendable {
        var backend: String
        var tartBaseImage: String
        var tartSSHUser: String

        @MainActor
        init(settings: AppSettings) {
            self.backend = settings.testingEnvironmentRaw
            self.tartBaseImage = settings.tartBaseImage
            self.tartSSHUser = settings.tartSSHUser
        }
    }

    /// Build an environment based on the configured backend. Returns
    /// `nil` for `.none` — the caller skips install steps.
    static func make(configuration: Configuration) async throws -> (any TestEnvironment)? {
        switch configuration.backend {
        case "host":
            return HostTestEnvironment()
        case "tart":
            let detector = TartDetector()
            guard let tartPath = await detector.locate() else {
                throw FactoryError.tartUnavailable
            }
            let baseImage = configuration.tartBaseImage.trimmingCharacters(in: .whitespaces)
            guard !baseImage.isEmpty else {
                throw FactoryError.missingBaseImage
            }
            let sshUser = configuration.tartSSHUser.trimmingCharacters(in: .whitespaces)
            return TartTestEnvironment(
                tartPath: tartPath,
                baseImage: baseImage,
                sshUser: sshUser.isEmpty ? "admin" : sshUser
            )
        default:
            return nil
        }
    }
}
