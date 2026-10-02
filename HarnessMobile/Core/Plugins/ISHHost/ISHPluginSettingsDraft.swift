import Foundation

enum ISHPluginSettingsDraftError: LocalizedError, Sendable, Equatable {
    case invalidUserLayer
    case schemaChanged

    var errorDescription: String? {
        switch self {
        case .invalidUserLayer:
            return "The user layer of the plugin settings is not an object and cannot be edited safely."
        case .schemaChanged:
            return "The config schema changed after the plugin update. Reload before editing."
        }
    }
}

/// Stages edits over the official Settings user layer. Presence in `user`
/// means override even when the value equals the inherited/default value.
struct ISHPluginSettingsDraft: Sendable, Equatable {
    let namespace: String
    let expectedRevision: Int
    let schema: JSONValue?

    private let baselineUser: JSONValue
    private let baselineValue: JSONValue
    private let base: JSONValue?
    private let fieldPaths: [[String]]
    private(set) var user: JSONValue

    init(
        namespace descriptor: ISHPluginSettingsNamespace,
        form: ISHPluginSettingsForm
    ) throws {
        let user = descriptor.user ?? .object([:])
        guard case .object = user else {
            throw ISHPluginSettingsDraftError.invalidUserLayer
        }

        namespace = descriptor.ns
        expectedRevision = descriptor.revision
        schema = descriptor.schema
        baselineUser = user
        baselineValue = descriptor.value
        base = descriptor.base
        fieldPaths = Self.uniquePaths(form.visibleLeafFields.map(\.path))
        self.user = user
    }

    var operations: [ISHPluginSettingsPathOperation] {
        fieldPaths.compactMap { path in
            let hadValue = ISHPluginSettingsValue.contains(path: path, in: baselineUser)
            let hasValue = ISHPluginSettingsValue.contains(path: path, in: user)
            let oldValue = ISHPluginSettingsValue.value(at: path, in: baselineUser)
            let newValue = ISHPluginSettingsValue.value(at: path, in: user)

            if hasValue, let newValue {
                if hadValue, oldValue == newValue { return nil }
                return .set(path: path, value: newValue)
            }
            return hadValue ? .unset(path: path) : nil
        }
    }

    var isDirty: Bool { !operations.isEmpty }

    var overriddenFieldCount: Int {
        fieldPaths.count { isOverridden(at: $0) }
    }

    func isOverridden(at path: [String]) -> Bool {
        ISHPluginSettingsValue.contains(path: path, in: user)
    }

    func effectiveValue(for field: ISHPluginSettingsField) -> JSONValue? {
        if let value = ISHPluginSettingsValue.value(at: field.path, in: user) {
            return value
        }
        return fallbackValue(for: field)
    }

    func fallbackValue(for field: ISHPluginSettingsField) -> JSONValue? {
        if let value = ISHPluginSettingsValue.value(at: field.path, in: base) {
            return value
        }
        if let defaultValue = field.defaultValue {
            return defaultValue
        }
        if !ISHPluginSettingsValue.contains(path: field.path, in: baselineUser) {
            return ISHPluginSettingsValue.value(at: field.path, in: baselineValue)
        }
        return nil
    }

    mutating func set(_ value: JSONValue, at path: [String]) {
        guard !path.isEmpty else { return }
        user = Self.setting(value, at: path, in: user)
    }

    mutating func reset(_ path: [String]) {
        guard !path.isEmpty else { return }
        user = Self.deleting(path, in: user)
    }

    func validationIssues(in form: ISHPluginSettingsForm) -> [String] {
        form.rootFields.compactMap(validationIssue(for:))
            + form.groups.flatMap { $0.fields.compactMap(validationIssue(for:)) }
    }

    func rebased(
        onto descriptor: ISHPluginSettingsNamespace,
        form: ISHPluginSettingsForm
    ) throws -> ISHPluginSettingsDraft {
        guard descriptor.schema == schema else {
            throw ISHPluginSettingsDraftError.schemaChanged
        }

        var rebased = try ISHPluginSettingsDraft(namespace: descriptor, form: form)
        for operation in operations {
            switch operation.op {
            case .set:
                guard let value = operation.value else { continue }
                rebased.set(value, at: operation.path)
            case .unset:
                rebased.reset(operation.path)
            }
        }
        return rebased
    }

    private func validationIssue(for leaf: ISHPluginSettingsLeaf) -> String? {
        guard !leaf.disabled else { return nil }
        let field = leaf.field
        guard let value = effectiveValue(for: field) else {
            return field.required ? "\(leaf.label) is missing a required value." : nil
        }

        switch field.kind {
        case .boolean:
            guard case .bool = value else { return "\(leaf.label) must be a toggle value." }
        case let .number(minimum, maximum, step):
            guard case let .number(number) = value, number.isFinite else {
                return "\(leaf.label) must be a finite number."
            }
            if let minimum, number < minimum {
                return "\(leaf.label) cannot be less than \(minimum.formatted())."
            }
            if let maximum, number > maximum {
                return "\(leaf.label) cannot be greater than \(maximum.formatted())."
            }
            if let step, step > 0 {
                let origin = minimum ?? 0
                let quotient = (number - origin) / step
                if abs(quotient - quotient.rounded()) > 1e-8 {
                    return "\(leaf.label) must be a multiple of step \(step.formatted())."
                }
            }
        case .string:
            guard case .string = value else { return "\(leaf.label) must be text." }
        case let .selection(options):
            guard options.contains(where: { $0.value == value }) else {
                return "\(leaf.label) is not an option allowed by the schema."
            }
        case .object:
            return nil
        }
        return nil
    }

    private static func uniquePaths(_ paths: [[String]]) -> [[String]] {
        var seen = Set<[String]>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func setting(
        _ value: JSONValue,
        at path: ArraySlice<String>,
        in root: JSONValue
    ) -> JSONValue {
        guard let head = path.first else { return root }
        var object = root.objectValue ?? [:]
        if path.count == 1 {
            object[head] = value
        } else {
            object[head] = setting(
                value,
                at: path.dropFirst(),
                in: object[head] ?? .object([:])
            )
        }
        return .object(object)
    }

    private static func setting(
        _ value: JSONValue,
        at path: [String],
        in root: JSONValue
    ) -> JSONValue {
        setting(value, at: path[...], in: root)
    }

    private static func deleting(
        _ path: ArraySlice<String>,
        in root: JSONValue
    ) -> JSONValue {
        guard let head = path.first,
              var object = root.objectValue else { return root }
        if path.count == 1 {
            object.removeValue(forKey: head)
        } else if let child = object[head] {
            object[head] = deleting(path.dropFirst(), in: child)
        }
        return .object(object)
    }

    private static func deleting(_ path: [String], in root: JSONValue) -> JSONValue {
        deleting(path[...], in: root)
    }
}
