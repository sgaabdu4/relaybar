import Foundation

struct CodexLine {
    var text: String
    var heading: [String]?
    var key: [String]?
    var value: String
    var table: [String]
    var continuation: Bool
}

extension PoolReplace {
    static func codexLines(_ existing: String) -> [CodexLine] {
        var found: [CodexLine] = []
        var table: [String] = []
        var open: String?
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            var entry = CodexLine(text: line, heading: nil, key: nil, value: "", table: table, continuation: false)
            if let delimiter = open {
                entry.continuation = true
                if line.components(separatedBy: delimiter).count % 2 == 0 { open = nil }
            } else {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("["), let parts = headingParts(text) {
                    table = parts
                    entry.heading = parts
                    entry.table = parts
                } else if let equals = equalsIndex(text), let key = keyParts(text[..<equals]) {
                    entry.key = key
                    entry.value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    for delimiter in ["\"\"\"", "'''"] where entry.value.hasPrefix(delimiter) {
                        if entry.value.dropFirst(3).components(separatedBy: delimiter).count < 2 { open = delimiter }
                    }
                }
            }
            found.append(entry)
        }
        return found
    }

    private static func headingParts(_ text: String) -> [String]? {
        let inner = text.drop { $0 == "[" }
        var closing: String.Index?
        var quote: Character?
        for index in inner.indices {
            let character = inner[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                closing = index
                break
            }
        }
        guard let closing else { return nil }
        return keyParts(inner[..<closing])
    }

    private static func equalsIndex(_ text: String) -> String.Index? {
        var quote: Character?
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            } else if character == "#" {
                return nil
            }
        }
        return nil
    }

    private static func keyParts(_ text: Substring) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var quoted = false
        func finish() {
            parts.append(quoted ? current : current.trimmingCharacters(in: .whitespaces))
            current = ""
            quoted = false
        }
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                quoted = true
                current = ""
            } else if character == "." {
                finish()
            } else if !(quoted && character == " ") {
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        finish()
        return parts.contains("") ? nil : parts
    }

    private static func isRelaybarTable(_ parts: [String]) -> Bool { parts.starts(with: ["model_providers", "relaybar"]) }

    private static func ownsProvider(_ value: String) -> Bool {
        for quote in ["\"relaybar\"", "'relaybar'"] where value.hasPrefix(quote) {
            let rest = value.dropFirst(quote.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty || rest.hasPrefix("#")
        }
        return false
    }

    static func codexKept(_ existing: String, ownProviderOnly: Bool = false) -> (kept: [String], provider: String?) {
        var kept: [String] = []
        var provider: String?
        var tableDropped = false
        var valueDropped = false
        for line in codexLines(existing) {
            var drop = tableDropped
            if line.continuation {
                drop = valueDropped
            } else if let heading = line.heading {
                tableDropped = isRelaybarTable(heading)
                valueDropped = false
                drop = tableDropped
            } else if let key = line.key {
                let top = line.table.isEmpty && key == ["model_provider"] && (!ownProviderOnly || ownsProvider(line.value))
                drop = drop || top || isRelaybarTable(line.table + key) || (line.table == ["model_providers"] && key.first == "relaybar")
                valueDropped = drop
                if top { provider = provider ?? line.text }
            } else {
                valueDropped = false
            }
            if !drop { kept.append(line.text) }
        }
        return (kept, provider)
    }
}
