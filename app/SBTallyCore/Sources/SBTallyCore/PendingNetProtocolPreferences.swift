import Foundation

public struct PendingNetProtocolSelection: Codable, Equatable, Sendable {
    public let selectorTag: String
    public let members: [String]
    public var selected: String?
    public init(selectorTag: String, members: [String], selected: String?) { self.selectorTag = selectorTag; self.members = members; self.selected = selected }
}

public struct PendingNetProtocolPreferences {
    private let defaults: UserDefaults
    private static let snapshotKey = "pendingnet.protocol-options"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> PendingNetProtocolSelection? {
        guard let data = defaults.data(forKey: Self.snapshotKey),
              let value = try? JSONDecoder().decode(PendingNetProtocolSelection.self, from: data),
              !value.members.isEmpty, value.members.allSatisfy({ $0.hasPrefix(value.selectorTag + "-") }) else { return nil }
        return value
    }
    public func capture(selector: String, members: [String], selected: String?) -> PendingNetProtocolSelection {
        let value = PendingNetProtocolSelection(selectorTag: selector, members: members, selected: selected)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.snapshotKey) }
        return value
    }
    public func capture(runtime: PendingNetRuntimeServer) throws -> PendingNetProtocolSelection {
        let (_, tags) = try runtime.managedProxyOutbounds()
        let members = tags + [runtime.selectorTag + "-mix"]
        let saved = PendingNetSelectorPreferences(defaults: defaults).selections[runtime.selectorTag]
        return capture(selector: runtime.selectorTag, members: members, selected: saved.flatMap { members.contains($0) ? $0 : nil } ?? members.first)
    }
    public func select(_ tag: String, in value: PendingNetProtocolSelection) -> PendingNetProtocolSelection? {
        guard value.members.contains(tag) else { return nil }
        PendingNetSelectorPreferences(defaults: defaults).remember(selector: value.selectorTag, selection: tag)
        return capture(selector: value.selectorTag, members: value.members, selected: tag)
    }
    public func forget(serverID: String) {
        let selector = PendingNetRuntimeServer.selectorTag(forServerID: serverID)
        if load()?.selectorTag == selector { defaults.removeObject(forKey: Self.snapshotKey) }
        var choices = PendingNetSelectorPreferences(defaults: defaults).selections
        choices.removeValue(forKey: selector)
        if choices["proxy"] == selector { choices.removeValue(forKey: "proxy") }
        defaults.set(choices, forKey: PendingNetSelectorPreferences.selectionsKey)
    }
    public func applying(to data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbounds = root["outbounds"] as? [[String: Any]] else { throw PendingNetRuntimeConfigError.invalidLocalConfiguration }
        let saved = PendingNetSelectorPreferences(defaults: defaults).selections
        for i in outbounds.indices {
            guard outbounds[i]["type"] as? String == "selector", let tag = outbounds[i]["tag"] as? String,
                  let members = outbounds[i]["outbounds"] as? [String], let selected = saved[tag], members.contains(selected) else { continue }
            outbounds[i]["default"] = selected
        }
        root["outbounds"] = outbounds
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
