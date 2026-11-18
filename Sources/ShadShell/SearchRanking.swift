import ShadCore
import Foundation

private let searchLocale = Locale(identifier: "en_US_POSIX")

private func folded(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: searchLocale)
}

private func words(_ value: String) -> [Substring] {
    value.split { !$0.isLetter && !$0.isNumber }
}

private func abbreviationMatches(_ term: Substring, in word: Substring) -> Bool {
    guard term.count >= 3, term.first == word.first, word.count <= term.count * 4 else { return false }
    var letters = term.makeIterator()
    var wanted = letters.next()
    for letter in word where letter == wanted {
        wanted = letters.next()
        if wanted == nil { return true }
    }
    return false
}

/// Retains the supplied order for equally relevant items and for an empty query.
@MainActor
func rankedCommands(_ commands: [ToolCommand], query: String) -> [ToolCommand] {
    let needle = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !needle.isEmpty else { return commands }
    let tokens = needle.split(whereSeparator: \.isWhitespace)

    func score(_ command: ToolCommand) -> Int? {
        let title = folded(command.title)
        if title == needle { return 1000 }
        if title.hasPrefix(needle) { return 900 }
        let titleWords = words(title)
        let initials = String(titleWords.compactMap(\.first))
        if needle.count > 1, initials.hasPrefix(needle) { return 825 }
        if title.contains(needle) { return 800 }

        let aliases = folded(command.keywords)
        let group = folded(command.group)
        let subtitle = folded(command.subtitle)
        var points = 0
        for token in tokens {
            if titleWords.contains(token) { points += 75 }
            else if titleWords.contains(where: { $0.hasPrefix(token) }) { points += 68 }
            else if title.contains(token) { points += 58 }
            else if titleWords.contains(where: { abbreviationMatches(token, in: $0) }) { points += 45 }
            else if aliases.contains(token) { points += 35 }
            else if group.contains(token) { points += 25 }
            else if subtitle.contains(token) { points += 15 }
            else { return nil }
        }
        return points / max(1, tokens.count)
    }

    var matches: [(command: ToolCommand, score: Int, offset: Int)] = []
    for (offset, command) in commands.enumerated() {
        if let relevance = score(command) { matches.append((command, relevance, offset)) }
    }
    matches.sort { lhs, rhs in
        lhs.score == rhs.score ? lhs.offset < rhs.offset : lhs.score > rhs.score
    }
    return matches.map(\.command)
}
