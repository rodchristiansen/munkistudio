import Foundation
import PredicateBridge

/// Best-effort parser from an NSPredicate source string to a
/// ``PredicateModel``. When in doubt we hand the string back as
/// ``PredicateModel/raw(_:)`` — the editor uses that to fall back to a
/// plain-text expression field.
///
/// We rely on `NSPredicate(format:)` to validate and on
/// `NSCompoundPredicate` / `NSComparisonPredicate` introspection to recover
/// structure. That lets us handle the common shapes without writing a full
/// NSPredicate grammar. ObjC exception → Swift throw bridging lives in
/// ``PredicateBridge``.
public enum PredicateParser {
    public static func parse(_ source: String) -> PredicateModel {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw(source) }

        var error: NSError?
        guard let predicate = PBSafelyCreatePredicate(trimmed, &error), error == nil else {
            return .raw(source)
        }
        return convert(predicate) ?? .raw(source)
    }

    private static func convert(_ predicate: NSPredicate) -> PredicateModel? {
        if let compound = predicate as? NSCompoundPredicate {
            switch compound.compoundPredicateType {
            case .and:
                let children = compound.subpredicates.compactMap { sub -> PredicateModel? in
                    guard let sub = sub as? NSPredicate else { return nil }
                    return convert(sub)
                }
                return .compound(.init(kind: .and, children: children))
            case .or:
                let children = compound.subpredicates.compactMap { sub -> PredicateModel? in
                    guard let sub = sub as? NSPredicate else { return nil }
                    return convert(sub)
                }
                return .compound(.init(kind: .or, children: children))
            case .not:
                guard let inner = compound.subpredicates.first as? NSPredicate,
                      let model = convert(inner) else { return nil }
                return .not(model)
            @unknown default:
                return nil
            }
        }
        if let comparison = predicate as? NSComparisonPredicate {
            return convert(comparison)
        }
        return nil
    }

    private static func convert(_ comparison: NSComparisonPredicate) -> PredicateModel? {
        guard let key = comparison.leftExpression.stringRepresentation() else { return nil }
        guard let op = mapOperator(comparison.predicateOperatorType) else { return nil }
        let value = convertValue(comparison.rightExpression)
        let modifiers = mapModifiers(comparison.options)
        return .comparison(.init(leftKey: key, op: op, rightValue: value, modifiers: modifiers))
    }

    private static func mapOperator(_ type: NSComparisonPredicate.Operator) -> PredicateModel.Operator? {
        switch type {
        case .equalTo: .equal
        case .notEqualTo: .notEqual
        case .lessThan: .lessThan
        case .lessThanOrEqualTo: .lessThanOrEqual
        case .greaterThan: .greaterThan
        case .greaterThanOrEqualTo: .greaterThanOrEqual
        case .beginsWith: .beginsWith
        case .contains: .contains
        case .endsWith: .endsWith
        case .like: .like
        case .matches: .matches
        case .in: .in
        default: nil
        }
    }

    private static func mapModifiers(_ options: NSComparisonPredicate.Options) -> [PredicateModel.Modifier] {
        var modifiers: [PredicateModel.Modifier] = []
        if options.contains(.caseInsensitive) { modifiers.append(.caseInsensitive) }
        if options.contains(.diacriticInsensitive) { modifiers.append(.diacriticInsensitive) }
        return modifiers
    }

    private static func convertValue(_ expression: NSExpression) -> PredicateModel.Value {
        switch expression.expressionType {
        case .constantValue:
            let value = expression.constantValue
            if let bool = value as? Bool { return .bool(bool) }
            if let number = value as? NSNumber, !(value is Bool) {
                return .number(number.doubleValue)
            }
            if let string = value as? String { return .string(string) }
            if let array = value as? [Any] {
                return .list(array.map { convertConstant($0) })
            }
            return .string(String(describing: value ?? ""))
        case .keyPath:
            return .identifier(expression.keyPath)
        case .aggregate:
            if let collection = expression.collection as? [NSExpression] {
                return .list(collection.map(convertValue))
            }
            return .list([])
        default:
            return .string(expression.description)
        }
    }

    private static func convertConstant(_ value: Any) -> PredicateModel.Value {
        if let bool = value as? Bool { return .bool(bool) }
        if let number = value as? NSNumber, !(value is Bool) {
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        return .string(String(describing: value))
    }
}

private extension NSExpression {
    func stringRepresentation() -> String? {
        switch expressionType {
        case .keyPath: keyPath
        case .constantValue: (constantValue as? String) ?? String(describing: constantValue ?? "")
        default: description
        }
    }
}
