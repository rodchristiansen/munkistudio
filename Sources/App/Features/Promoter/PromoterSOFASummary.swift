import SwiftUI
import Foundation

/// A compact Apple update reference, separate from repository app assessments.
struct PromoterSOFASummary: View {
    @State private var summary = "macOS security updates"

    var body: some View {
        HStack(spacing: 6) {
            Text("SOFA · \(summary)")
                .foregroundStyle(.secondary)
            Link("Details ↗", destination: URL(string: "https://sofa.macadmins.io/")!)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task {
            // No repository or device identifiers are included in this public feed request.
            var request = URLRequest(url: URL(string: "https://sofafeed.macadmins.io/v1/macos_data_feed.json")!)
            request.setValue("MunkiStudio/1.0 (SOFA summary)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let feed = try JSONDecoder().decode(SOFAFeed.self, from: data)
                guard let latest = feed.OSVersions.max(by: {
                    $0.Latest.ProductVersion.compare($1.Latest.ProductVersion, options: .numeric) == .orderedAscending
                })?.Latest, let count = latest.UniqueCVEsCount, count > 0 else { return }
                try Task.checkCancellation()
                summary = "macOS \(latest.ProductVersion) fixes \(count) vulnerabilities"
            } catch {
                // Keep the useful SOFA link when offline or when the feed changes.
            }
        }
    }
}

private struct SOFAFeed: Decodable {
    let OSVersions: [OSVersion]

    struct OSVersion: Decodable {
        let Latest: Release
    }

    struct Release: Decodable {
        let ProductVersion: String
        let UniqueCVEsCount: Int?
    }
}
