import Foundation
import Testing
@testable import Core

@Suite("Predicate parser + serializer")
struct PredicateTests {
    @Test("parses a simple equality")
    func parsesEquality() {
        let model = PredicateParser.parse("arch == \"arm64\"")
        guard case .comparison(let comparison) = model else {
            Issue.record("Expected comparison, got \(model)")
            return
        }
        #expect(comparison.leftKey == "arch")
        #expect(comparison.op == .equal)
        #expect(comparison.rightValue == .string("arm64"))
    }

    @Test("parses a compound AND")
    func parsesCompoundAnd() {
        let model = PredicateParser.parse("arch == \"arm64\" AND os_vers >= \"12.0\"")
        guard case .compound(let compound) = model else {
            Issue.record("Expected compound, got \(model)")
            return
        }
        #expect(compound.kind == .and)
        #expect(compound.children.count == 2)
    }

    @Test("round-trips a simple expression")
    func roundTripsSimpleExpression() {
        let source = "arch == \"arm64\""
        let model = PredicateParser.parse(source)
        let serialized = PredicateSerializer.serialize(model)
        let reparsed = PredicateParser.parse(serialized)
        #expect(model == reparsed)
    }

    @Test("falls back to raw when unparseable")
    func raw() {
        let model = PredicateParser.parse("this is not a valid predicate at all !!!")
        if case .raw = model {
            // expected
        } else {
            Issue.record("Expected raw fallback, got \(model)")
        }
    }
}
