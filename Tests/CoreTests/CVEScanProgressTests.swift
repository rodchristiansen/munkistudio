import Foundation
import Testing
@testable import Core

@Suite("CVE scan progress snapshots")
struct CVEScanProgressTests {
    @Test("active workers stay visible when another app finishes")
    func activeLookups() throws {
        let line = #"CVE_PROGRESS {"phase":"querying","completed":40,"total":42,"active":[{"name":"Chrome","page":14,"attempt":2,"status":"querying"},{"name":"Wireshark","page":2,"attempt":1,"status":"retrying","detail":"HTTP 503"}]}"#
        let progress = try #require(CVEScanProgress.parse(line))
        #expect(progress.summary.contains("40/42 apps checked"))
        #expect(progress.summary.contains("Checking Chrome (page 14, attempt 2/3)"))
        #expect(progress.summary.contains("Retrying Wireshark"))
        #expect(progress.summary.contains("HTTP 503"))
        #expect(!progress.summary.contains("Zotero"))
        #expect(CVEScanProgress.parse("Checked Zotero: complete") == nil)
    }

    @Test("completed queries explain the remaining assessment and save phases")
    func finalPhases() throws {
        let assessing = try #require(CVEScanProgress.parse(#"CVE_PROGRESS {"phase":"assessing","completed":42,"total":42,"active":[]}"#))
        #expect(assessing.summary.contains("Assessing advisory"))
        let saving = try #require(CVEScanProgress.parse(#"CVE_PROGRESS {"phase":"saving","completed":42,"total":42,"active":[]}"#))
        #expect(saving.summary.contains("Saving"))
    }

    @Test("invalid progress cannot claim impossible completion")
    func invalidCounts() {
        #expect(CVEScanProgress.parse(#"CVE_PROGRESS {"phase":"querying","completed":43,"total":42,"active":[]}"#) == nil)
        #expect(CVEScanProgress.parse("CVE_PROGRESS invalid JSON") == nil)
    }
}
