import Foundation

/// Shape for `preinstall_alert`, `preuninstall_alert`, and
/// `preupgrade_alert` — a dict shown to the user before an action.
public struct PreinstallAlert: Sendable, Hashable, Codable {
    public var alertTitle: String?
    public var alertDetail: String?
    public var okLabel: String?
    public var cancelLabel: String?
    public var enabled: Bool?

    public init(
        alertTitle: String? = nil,
        alertDetail: String? = nil,
        okLabel: String? = nil,
        cancelLabel: String? = nil,
        enabled: Bool? = nil
    ) {
        self.alertTitle = alertTitle
        self.alertDetail = alertDetail
        self.okLabel = okLabel
        self.cancelLabel = cancelLabel
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case alertTitle = "alert_title"
        case alertDetail = "alert_detail"
        case okLabel = "ok_label"
        case cancelLabel = "cancel_label"
        case enabled
    }
}
