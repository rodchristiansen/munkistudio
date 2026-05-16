import Foundation
import Testing
@testable import Core

@Suite("Dependency linter")
struct DependencyLinterTests {
    private func pkg(_ name: String, requires: [String]? = nil, updateFor: [String]? = nil) -> Pkginfo {
        var pkginfo = Pkginfo(name: name)
        pkginfo.requires = requires
        pkginfo.updateFor = updateFor
        return pkginfo
    }

    private func analyze(_ pkginfos: [Pkginfo]) -> [DependencyFinding] {
        DependencyLinter.analyze(DependencyGraphBuilder.build(pkginfos: pkginfos))
    }

    @Test("a clean graph produces no findings")
    func cleanGraph() {
        let findings = analyze([
            pkg("App", requires: ["Helper"]),
            pkg("Helper"),
        ])
        #expect(findings.isEmpty)
    }

    @Test("flags a circular requires chain")
    func detectsCycle() {
        let findings = analyze([
            pkg("A", requires: ["B"]),
            pkg("B", requires: ["A"]),
        ])
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .cycle)
        #expect(findings.first?.severity == .error)
        #expect(Set(findings.first?.nodes ?? []) == ["A", "B"])
    }

    @Test("flags a requirement already implied transitively")
    func detectsRedundantRequires() {
        let findings = analyze([
            pkg("App", requires: ["Mid", "Base"]),
            pkg("Mid", requires: ["Base"]),
            pkg("Base"),
        ])
        let redundant = findings.filter { $0.kind == .redundantRequires }
        #expect(redundant.count == 1)
        #expect(redundant.first?.nodes == ["App", "Base"])
    }

    @Test("a non-redundant direct requirement is not flagged")
    func keepsNecessaryRequires() {
        let findings = analyze([
            pkg("App", requires: ["Mid"]),
            pkg("Mid", requires: ["Base"]),
            pkg("Base"),
        ])
        #expect(findings.contains { $0.kind == .redundantRequires } == false)
    }

    @Test("flags the same pkginfo listing a name in requires and update_for")
    func detectsConflictingRelationship() {
        let findings = analyze([
            pkg("A", requires: ["B"], updateFor: ["B"]),
            pkg("B"),
        ])
        let conflict = findings.filter { $0.kind == .conflictingRelationship }
        #expect(conflict.count == 1)
        #expect(conflict.first?.severity == .warning)
    }

    @Test("flags an overlap declared from opposite sides")
    func detectsReverseOverlap() {
        // A requires B, and B is update_for A — the Excel / OfficePrefs case.
        let findings = analyze([
            pkg("Excel", requires: ["OfficePrefs"]),
            pkg("OfficePrefs", updateFor: ["Excel"]),
        ])
        let conflict = findings.filter { $0.kind == .conflictingRelationship }
        #expect(conflict.count == 1)
        #expect(Set(conflict.first?.nodes ?? []) == ["Excel", "OfficePrefs"])
    }

    @Test("flags a reference to a package not in the repo")
    func detectsDanglingReference() {
        let findings = analyze([pkg("App", requires: ["Ghost"])])
        let dangling = findings.filter { $0.kind == .danglingReference }
        #expect(dangling.count == 1)
        #expect(dangling.first?.nodes.first == "Ghost")
    }

    @Test("errors sort ahead of warnings")
    func errorsSortFirst() {
        let findings = analyze([
            pkg("A", requires: ["B"]),
            pkg("B", requires: ["A"]),
            pkg("C", requires: ["Ghost"]),
        ])
        #expect(findings.first?.severity == .error)
    }
}
