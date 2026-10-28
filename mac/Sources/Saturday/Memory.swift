import Foundation

struct MemoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var date = Date()
}

/// Long-term facts about the user that personalize every answer. The models add to it by ending a
/// reply with <remember>…</remember>; the user can also say "remember that…" or edit it in Settings.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var items: [MemoryItem] = []

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saturday", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url) {
            items = (try? JSONDecoder().decode([MemoryItem].self, from: data)) ?? []
        }
    }

    func add(_ text: String) {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard fact.count > 2, !items.contains(where: { $0.text.caseInsensitiveCompare(fact) == .orderedSame }) else { return }
        items.append(MemoryItem(text: fact))
        if items.count > 200 { items.removeFirst(items.count - 200) }
        save()
    }

    func remove(_ item: MemoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Removes facts that mention every word of the query. Returns how many were removed.
    @discardableResult
    func forget(matching query: String) -> Int {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 2 }
        guard !words.isEmpty else { return 0 }
        let before = items.count
        items.removeAll { item in words.allSatisfy { item.text.lowercased().contains($0) } }
        save()
        return before - items.count
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Splits a finished reply into what to show and the facts to remember.
    nonisolated static func extract(from text: String) -> (clean: String, facts: [String]) {
        guard let regex = try? NSRegularExpression(pattern: "<remember>([\\s\\S]*?)</remember>") else { return (text, []) }
        let range = NSRange(text.startIndex..., in: text)
        let facts = regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
        let clean = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (visible(clean).trimmingCharacters(in: .whitespacesAndNewlines), facts)
    }

    /// Hides a memory tag while it is still streaming in.
    nonisolated static func visible(_ text: String) -> String {
        if let start = text.range(of: "<remember") { return String(text[..<start.lowerBound]) }
        if let lt = text.lastIndex(of: "<"), "<remember".hasPrefix(text[lt...]) { return String(text[..<lt]) }
        return text
    }
}

enum DisplayText {
    /// What the user sees: no memory tags and no voice cues like <laugh>.
    static func clean(_ text: String) -> String {
        var s = MemoryStore.visible(text)
        // The hidden <tone> tag at the start tells the voice how to say the reply.
        let lead = s.drop { $0.isWhitespace }
        if lead.hasPrefix("<tone>") {
            guard let close = lead.range(of: "</tone>") else { return "" }
            s = String(lead[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !lead.isEmpty, "<tone>".hasPrefix(lead) {
            return ""
        }
        for cue in SpeechText.cues { s = s.replacingOccurrences(of: cue, with: "") }
        if let lt = s.lastIndex(of: "<"), SpeechText.cues.contains(where: { $0.hasPrefix(s[lt...]) }) {
            s = String(s[..<lt])
        }
        return s.replacingOccurrences(of: "  ", with: " ")
    }
}
