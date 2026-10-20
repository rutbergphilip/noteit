import Foundation

/// Languages a code block can be set to. Raw values are persisted in notes (the editor writes them as a
/// code-language tab stop), so they must never change; add new cases at the end. Moved from the app in
/// foundations Task 2.1.
public enum CodeLanguage: Int, CaseIterable, Identifiable, Sendable {
    case plain = 1, bash, c, cpp, csharp, css, go, html, java, javascript, json, kotlin, markdown, php, python, ruby, rust, sql, swift, typescript, yaml

    public var id: Int { rawValue }

    /// Canonical lowercase id, used in Markdown fences and `language-x` HTML classes.
    public var identifier: String {
        switch self {
        case .plain: "text"
        case .bash: "bash"
        case .c: "c"
        case .cpp: "cpp"
        case .csharp: "csharp"
        case .css: "css"
        case .go: "go"
        case .html: "html"
        case .java: "java"
        case .javascript: "javascript"
        case .json: "json"
        case .kotlin: "kotlin"
        case .markdown: "markdown"
        case .php: "php"
        case .python: "python"
        case .ruby: "ruby"
        case .rust: "rust"
        case .sql: "sql"
        case .swift: "swift"
        case .typescript: "typescript"
        case .yaml: "yaml"
        }
    }

    public var displayName: String {
        switch self {
        case .plain: "Plain Text"
        case .bash: "Bash/Shell"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .css: "CSS"
        case .go: "Go"
        case .html: "HTML/XML"
        case .java: "Java"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .kotlin: "Kotlin"
        case .markdown: "Markdown"
        case .php: "PHP"
        case .python: "Python"
        case .ruby: "Ruby"
        case .rust: "Rust"
        case .sql: "SQL"
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .yaml: "YAML"
        }
    }

    /// Short name for the code block's corner label.
    public var shortName: String {
        switch self {
        case .bash: "Shell"
        case .html: "HTML"
        default: displayName
        }
    }

    private static let aliases: [String: CodeLanguage] = [
        "text": .plain, "txt": .plain, "plain": .plain, "plaintext": .plain,
        "bash": .bash, "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash, "shellsession": .bash,
        "c": .c, "h": .c,
        "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp,
        "csharp": .csharp, "cs": .csharp, "c#": .csharp,
        "css": .css, "scss": .css,
        "go": .go, "golang": .go,
        "html": .html, "xml": .html, "xhtml": .html, "svg": .html, "plist": .html,
        "java": .java,
        "javascript": .javascript, "js": .javascript, "jsx": .javascript, "mjs": .javascript, "node": .javascript,
        "json": .json, "jsonc": .json,
        "kotlin": .kotlin, "kt": .kotlin, "kts": .kotlin,
        "markdown": .markdown, "md": .markdown,
        "php": .php,
        "python": .python, "py": .python, "python3": .python,
        "ruby": .ruby, "rb": .ruby,
        "rust": .rust, "rs": .rust,
        "sql": .sql, "mysql": .sql, "postgresql": .sql, "postgres": .sql, "sqlite": .sql,
        "swift": .swift,
        "typescript": .typescript, "ts": .typescript, "tsx": .typescript,
        "yaml": .yaml, "yml": .yaml,
    ]

    /// Parses a Markdown info string or alias (`py`, `c++`, `yml`…); nil when unknown.
    public init?(identifier raw: String) {
        let word = raw.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
        guard let language = Self.aliases[word.lowercased()] else { return nil }
        self = language
    }
}
