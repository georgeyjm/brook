import Foundation

/// Splits and joins argument lists the way a POSIX shell would, so power users can type
/// `--exclude='My Folder' --bwlimit=1000` into a single text field.
public enum ShellWords {
    public enum SplitError: Error, Equatable, Sendable {
        case unterminatedQuote
    }

    public static func split(_ text: String) throws(SplitError) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false

        for char in text {
            if escaping {
                current.append(char)
                escaping = false
                inWord = true
                continue
            }
            if let open = quote {
                if char == open {
                    quote = nil
                } else if char == "\\" && open == "\"" {
                    escaping = true
                } else {
                    current.append(char)
                }
                continue
            }
            switch char {
            case "\\":
                escaping = true
            case "'", "\"":
                quote = char
                inWord = true
            case " ", "\t", "\n":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(char)
                inWord = true
            }
        }
        if quote != nil || escaping { throw .unterminatedQuote }
        if inWord { words.append(current) }
        return words
    }

    public static func join(_ words: [String]) -> String {
        words.map { CommandBuilder.shellQuote($0) }.joined(separator: " ")
    }
}
