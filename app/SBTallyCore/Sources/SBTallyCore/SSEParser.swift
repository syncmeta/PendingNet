import Foundation

public enum SSEParser {
    /// Parses a single SSE line of the form `data: <json-array>` into live groups.
    public static func parse(dataLine line: String) -> [LiveAppGroup]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([LiveAppGroup].self, from: data)
    }
}
