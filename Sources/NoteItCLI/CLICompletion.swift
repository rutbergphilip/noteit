import Foundation
import NoteItAPI
import NoteItSync

enum CompletionShell: String, CaseIterable {
    case zsh, bash, fish
}

/// What a positional argument or option value completes to.
enum CompletionValues: Equatable {
    case none
    case notes
    case notebooks
    case tags
    case files
    case commands
    case choices([String])
}

struct CompletionArgument: Equatable {
    var name: String
    var values: CompletionValues

    init(_ name: String, _ values: CompletionValues = .none) {
        self.name = name
        self.values = values
    }
}

/// The `noteit completion` scripts, generated from `CommandSpec.all`.
enum CompletionScript {
    static let optionSummaries: [String: String] = [
        "title": "Note title",
        "notebook": "Notebook name or id",
        "tag": "Tag, repeat for more",
        "open": "Show the new note in NoteIt",
        "today": "Add to today's daily note",
        "start": "Add at the start instead of the end",
        "time": "Add the time",
        "format": "Output format",
        "limit": "Most results to print, 1 to 500",
        "permanent": "Delete a note in Recently Deleted for good",
        "data": "Request body: JSON, @file or @- for stdin",
        "scopes": "Access to ask for",
        "profile": "Use another sign-in",
        "json": "Print the Local API's JSON unchanged",
        "no-launch": "Don't open NoteIt when it isn't running",
        "help": "Show help",
    ]
    static let versionSummary = "Print noteit's version"
    static let repeatableOptions: Set<String> = ["tag"]

    static let setupHelp = """
        Installing the tool from NoteIt › Settings › Integrations also installs completion for zsh, bash and fish.
        zsh only loads completion when ~/.zshrc has this line:
          autoload -Uz compinit && compinit
        To set it up yourself instead:
          zsh   Add to ~/.zshrc, after compinit: source <(noteit completion zsh)
          bash  Add to ~/.bash_profile: eval "$(noteit completion bash)"
          fish  Run once: noteit completion fish > ~/.config/fish/completions/noteit.fish
        """

    static func generate(for shell: CompletionShell) -> String {
        switch shell {
        case .zsh: zsh()
        case .bash: bash()
        case .fish: fish()
        }
    }

    static var commandNames: [String] { CommandSpec.all.map(\.name) }

    /// Every value option of every command, plus the global ones. No name is a value option in one command and a
    /// flag in another, so the scripts can skip option values without knowing the command.
    static var allValueOptions: [String] {
        unique(CommandSpec.all.flatMap(\.valueOptions) + CommandSpec.globalValueOptions)
    }

    private static func options(of spec: CommandSpec) -> (values: [String], flags: [String]) {
        (spec.valueOptions + CommandSpec.globalValueOptions, spec.flags + CommandSpec.globalFlags)
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func summary(_ option: String) -> String { optionSummaries[option] ?? option }

    // MARK: zsh

    private static func zsh() -> String {
        var lines = [
            "#compdef noteit",
            "# Tab completion for noteit, from: noteit completion zsh",
            "",
            "_noteit_values() {",
            "  local kind=${argv[-1]} line",
            "  local -a candidates",
            #"  for line in ${(f)"$(command noteit __complete $kind "${(Q)PREFIX}" 2>/dev/null)"}; do"#,
            #"    candidates+=("${${line%%$'\t'*}//:/\\:}:${line#*$'\t'}")"#,
            "  done",
            "  _describe -t $kind ${kind%s} candidates",
            "}",
            "",
            "_noteit() {",
            "  local curcontext=$curcontext state state_descr line ret=1",
            "  typeset -A opt_args",
            "  local -a commands",
            "  commands=(",
        ]
        lines += CommandSpec.all.map { "    " + shellQuoted(zshDescribeEscaped($0.name) + ":" + $0.summary) }
        lines += [
            "  )",
            "  _arguments -C \\",
            "    " + shellQuoted("(- *)--version[\(zshBracketEscaped(versionSummary))]") + " \\",
            "    " + shellQuoted("(- *)-h[\(summary("help"))]") + " \\",
            "    " + shellQuoted("(- *)--help[\(summary("help"))]") + " \\",
            "    '1: :->command' \\",
            "    '*:: :->argument' && ret=0",
            "  case $state in",
            "    (command)",
            "      _describe -t commands 'noteit command' commands && ret=0",
            "      ;;",
            "    (argument)",
            "      curcontext=${curcontext%:*:*}:noteit-$words[1]:",
            "      case $words[1] in",
        ]
        for spec in CommandSpec.all {
            let (values, flags) = options(of: spec)
            var specs = values.map { option in
                let repeatable = repeatableOptions.contains(option) ? "*" : ""
                let values = spec.optionValues[option] ?? .none
                return "\(repeatable)--\(option)=[\(zshBracketEscaped(summary(option)))]:\(option):\(zshAction(values))"
            }
            for flag in flags {
                if flag == "help" {
                    specs += ["(- *)-h[\(summary(flag))]", "(- *)--help[\(summary(flag))]"]
                } else {
                    specs.append("--\(flag)[\(zshBracketEscaped(summary(flag)))]")
                }
            }
            specs += spec.arguments.enumerated().map { index, argument in
                "\(index + 1):\(argument.name):\(zshAction(argument.values))"
            }
            lines.append("        (\(spec.name))")
            lines.append("          _arguments -S \\")
            lines += specs.map { "            " + shellQuoted($0) + " \\" }
            lines.append("            && ret=0")
            lines.append("          ;;")
        }
        lines += [
            "      esac",
            "      ;;",
            "  esac",
            "  return ret",
            "}",
            "",
            "if [[ $zsh_eval_context[-1] == loadautofunc ]]; then",
            "  _noteit \"$@\"",
            "else",
            "  compdef _noteit noteit",
            "fi",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func zshAction(_ values: CompletionValues) -> String {
        switch values {
        case .none: " "
        case .notes: "_noteit_values notes"
        case .notebooks: "_noteit_values notebooks"
        case .tags: "_noteit_values tags"
        case .files: "_files"
        case .commands: "(\(commandNames.joined(separator: " ")))"
        case .choices(let choices): "(\(choices.joined(separator: " ")))"
        }
    }

    private static func zshBracketEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\[]:".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func zshDescribeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
    }

    /// Single quotes for zsh and bash: `'` becomes `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: bash

    private static func bash() -> String {
        let valued = " " + allValueOptions.map { "--\($0)" }.joined(separator: " ") + " "
        var lines = [
            "# Tab completion for noteit, from: noteit completion bash",
            "",
            "_noteit_values() {",
            "    local line unquoted kept",
            "    _noteit_unquote \"$cur\"",
            "    while IFS= read -r line; do",
            "        line=${line%%$'\\t'*}",
            "        [[ -n $line && $line == \"$kept\"* ]] && COMPREPLY+=(\"${line:${#kept}}\")",
            "    done < <(command noteit __complete \"$1\" \"$unquoted\" 2>/dev/null)",
            "}",
            "",
            "# Sets unquoted to the word as the shell will read it, and kept to the start of it, up to an unquoted = or :",
            "# in COMP_WORDBREAKS, that readline leaves in place: replies replace only what follows.",
            "_noteit_unquote() {",
            "    local word=$1 char quote= i=0",
            "    unquoted= kept=",
            "    while (( i < ${#word} )); do",
            "        char=${word:i:1}",
            "        if [[ $quote == \"'\" ]]; then",
            "            [[ $char == \"'\" ]] && quote= || unquoted+=$char",
            "        elif [[ $char == '\\' ]]; then",
            "            i=$((i + 1))",
            "            char=${word:i:1}",
            "            [[ $quote == '\"' && $char != [\\\"\\\\\\$\\`] ]] && unquoted+='\\'",
            "            unquoted+=$char",
            "        elif [[ $char == \"$quote\" ]]; then",
            "            quote=",
            "        elif [[ -z $quote && ( $char == \"'\" || $char == '\"' ) ]]; then",
            "            quote=$char",
            "        else",
            "            unquoted+=$char",
            "            [[ -z $quote && $char == [=:] && $COMP_WORDBREAKS == *$char* ]] && kept=$unquoted",
            "        fi",
            "        i=$((i + 1))",
            "    done",
            "}",
            "",
            "# The words up to the cursor as the shell will split them: bash 4 and later split COMP_WORDS at = and :.",
            "_noteit_words() {",
            "    local line=$COMP_LINE gap word i",
            "    words=()",
            "    for (( i = 0; i <= COMP_CWORD; i++ )); do",
            "        word=${COMP_WORDS[i]}",
            "        gap=${line%%[![:space:]]*}",
            "        line=${line#\"$gap\"}",
            "        line=${line#\"$word\"}",
            "        if (( i > 0 )) && [[ -z $gap ]]; then",
            "            words[${#words[@]} - 1]+=$word",
            "        else",
            "            words+=(\"$word\")",
            "        fi",
            "    done",
            "    cword=$((${#words[@]} - 1))",
            "}",
            "",
            "_noteit() {",
            "    local words cword",
            "    _noteit_words",
            "    local cur=${words[cword]} option=${words[cword-1]} word command=${words[1]} count=0 rest= i=2",
            "    local valued=\(shellQuoted(valued))",
            "    COMPREPLY=()",
            "    if (( cword == 1 )); then",
            "        COMPREPLY=($(compgen -W \(shellQuoted((commandNames + ["--version", "--help", "-h"]).joined(separator: " "))) -- \"$cur\"))",
            "        return 0",
            "    fi",
            "    if [[ $cur == --*=* && $valued == *\" ${cur%%=*} \"* ]]; then",
            "        option=${cur%%=*}",
            "        cur=${cur#*=}",
            "    fi",
            "    while (( i < cword )); do",
            "        word=${words[i]}",
            "        if [[ -n $rest ]]; then",
            "            count=$((count + 1))",
            "        elif [[ $word == -- ]]; then",
            "            rest=1",
            "        elif [[ $valued == *\" $word \"* ]]; then",
            "            i=$((i + 1))",
            "        elif [[ $word != -* || $word == - ]]; then",
            "            count=$((count + 1))",
            "        fi",
            "        i=$((i + 1))",
            "    done",
            "    if [[ -z $rest && $valued == *\" $option \"* ]]; then",
            "        case \"$command $option\" in",
        ]
        for spec in CommandSpec.all {
            for option in options(of: spec).values {
                guard let action = bashAction(spec.optionValues[option] ?? .none) else { continue }
                lines.append("            \(shellQuoted("\(spec.name) --\(option)"))) \(action) ;;")
            }
        }
        lines += [
            "        esac",
            "        return 0",
            "    fi",
            "    if [[ -z $rest && $cur == -* ]]; then",
            "        case $command in",
        ]
        for spec in CommandSpec.all {
            let (values, flags) = options(of: spec)
            let words = values.map { "--\($0)" } + flags.map { "--\($0)" } + (flags.contains("help") ? ["-h"] : [])
            lines.append("            \(shellQuoted(spec.name))) COMPREPLY=($(compgen -W \(shellQuoted(words.joined(separator: " "))) -- \"$cur\")) ;;")
        }
        lines += [
            "        esac",
            "        return 0",
            "    fi",
            "    case \"$command $count\" in",
        ]
        for spec in CommandSpec.all {
            for (index, argument) in spec.arguments.enumerated() {
                guard let action = bashAction(argument.values) else { continue }
                lines.append("        \(shellQuoted("\(spec.name) \(index)"))) \(action) ;;")
            }
        }
        lines += [
            "    esac",
            "    return 0",
            "}",
            "",
            "complete -o filenames -F _noteit noteit",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func bashAction(_ values: CompletionValues) -> String? {
        switch values {
        case .none: nil
        case .notes: "_noteit_values notes"
        case .notebooks: "_noteit_values notebooks"
        case .tags: "_noteit_values tags"
        case .files: "COMPREPLY=($(compgen -f -- \"$cur\"))"
        case .commands: "COMPREPLY=($(compgen -W \(shellQuoted(commandNames.joined(separator: " "))) -- \"$cur\"))"
        case .choices(let choices): "COMPREPLY=($(compgen -W \(shellQuoted(choices.joined(separator: " "))) -- \"$cur\"))"
        }
    }

    // MARK: fish

    private static func fish() -> String {
        var lines = [
            "# Tab completion for noteit, from: noteit completion fish",
            "",
            "function __noteit_values",
            "    command noteit __complete $argv[1] 2>/dev/null",
            "end",
            "",
            "function __noteit_needs_command",
            "    test (count (commandline -opc)) -eq 1",
            "end",
            "",
            "function __noteit_using -a name",
            "    set -l tokens (commandline -opc)",
            "    test (count $tokens) -ge 2; and test \"$tokens[2]\" = $name",
            "end",
            "",
            "# The words after the command that aren't options or option values.",
            "function __noteit_arguments",
            "    set -l tokens (commandline -opc)",
            "    set -e tokens[1]",
            "    set -q tokens[1]; and set -e tokens[1]",
            "    set -l valued " + allValueOptions.map { "--\($0)" }.joined(separator: " "),
            "    set -l rest 0",
            "    set -l skip 0",
            "    for token in $tokens",
            "        if test $skip = 1",
            "            set skip 0",
            "        else if test $rest = 1",
            "            echo $token",
            "        else if test \"$token\" = --",
            "            set rest 1",
            "        else if contains -- $token $valued",
            "            set skip 1",
            "        else if not string match -q -- '-?*' $token",
            "            echo $token",
            "        end",
            "    end",
            "end",
            "",
            "function __noteit_argument -a name index",
            "    __noteit_using $name; or return 1",
            "    test (count (__noteit_arguments)) -eq $index",
            "end",
            "",
            "complete -c noteit -f",
            "complete -c noteit -n __noteit_needs_command -l version -d \(fishQuoted(versionSummary))",
            "complete -c noteit -n __noteit_needs_command -s h -l help -d \(fishQuoted(summary("help")))",
        ]
        lines += CommandSpec.all.map {
            "complete -c noteit -n __noteit_needs_command -a \(fishQuoted($0.name)) -d \(fishQuoted($0.summary))"
        }
        for spec in CommandSpec.all {
            lines.append("")
            let condition = fishQuoted("__noteit_using \(spec.name)")
            let (values, flags) = options(of: spec)
            for option in values {
                let arguments = fishArguments(spec.optionValues[option] ?? .none).map { " " + $0 } ?? ""
                lines.append("complete -c noteit -n \(condition) -l \(option) -r -f\(arguments) -d \(fishQuoted(summary(option)))")
            }
            for flag in flags {
                let short = flag == "help" ? " -s h" : ""
                lines.append("complete -c noteit -n \(condition)\(short) -l \(flag) -d \(fishQuoted(summary(flag)))")
            }
            for (index, argument) in spec.arguments.enumerated() {
                guard let arguments = fishArguments(argument.values) else { continue }
                lines.append("complete -c noteit -n \(fishQuoted("__noteit_argument \(spec.name) \(index)")) \(arguments)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func fishArguments(_ values: CompletionValues) -> String? {
        switch values {
        case .none: nil
        case .notes: "-a '(__noteit_values notes)'"
        case .notebooks: "-a '(__noteit_values notebooks)'"
        case .tags: "-a '(__noteit_values tags)'"
        case .files: "-F"
        case .commands: "-a \(fishQuoted(commandNames.joined(separator: " ")))"
        case .choices(let choices): "-a \(fishQuoted(choices.joined(separator: " ")))"
        }
    }

    /// Single quotes for fish, where only `\` and `'` need escaping.
    static func fishQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// `noteit __complete notes|notebooks|tags [PREFIX]`, which the completion scripts run for live values. Prints one
/// `value<TAB>description` line per candidate, or nothing at all when NoteIt isn't running, the Local API is off, the
/// user isn't signed in or the answer takes too long. Never launches NoteIt and never asks for anything.
struct CompletionCandidates {
    static let command = "__complete"
    static let timeout: Duration = .milliseconds(300)
    static let noteLimit = 200

    enum Kind: String {
        case notes, notebooks, tags
    }

    var context: CLIContext
    var timeout = Self.timeout

    func run(_ arguments: [String]) async {
        guard let kind = arguments.first.flatMap(Kind.init(rawValue:)), arguments.count <= 2,
              let profile = try? CLIProfile.resolve(flag: nil, environment: context.environment),
              AppLocator.invalidAPIURL(in: context.environment) == nil
        else { return }
        let prefix = arguments.count == 2 ? arguments[1] : ""
        let environmentToken = AppEnvironment.nonEmpty("TOKEN", in: context.environment)
        let keychain = context.keychain
        let locator = context.locator
        let session = context.session
        let lines = await Self.firstResult(within: timeout) { () async -> [String] in
            guard let token = environmentToken ?? keychain.nonInteractive().token(profile: profile),
                  !Task.isCancelled else { return [] }
            return await Self.candidates(kind, prefix: prefix, locator: locator, token: token, session: session)
        }
        lines?.forEach(context.io.line)
    }

    /// `work`'s result, or nil once `timeout` has passed. Doesn't wait for `work` to finish, since a Keychain read
    /// can block in a way that can't be cancelled; the process exits right after anyway.
    static func firstResult<Value: Sendable>(within timeout: Duration,
                                             _ work: @escaping @Sendable () async -> Value) async -> Value? {
        let once = ResumeOnce<Value?>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            let worker = Task.detached { once.resume(await work()) }
            Task.detached {
                try? await Task.sleep(for: timeout)
                worker.cancel()
                once.resume(nil)
            }
        }
    }
    private static func candidates(_ kind: Kind, prefix: String, locator: AppLocator, token: String,
                                   session: URLSession) async -> [String] {
        guard case .ready(let url) = await locator.locate(launch: false) else { return [] }
        let client = NoteItAPIClient(baseURL: url, token: token, session: session)
        do {
            switch kind {
            case .notes:
                let page = try await client.send(.GET, "/notes", query: ["limit": String(noteLimit)],
                                                 as: Page<NoteSummaryDTO>.self)
                return noteLines(page.items, prefix: prefix)
            case .notebooks:
                return notebookLines(try await client.send(.GET, "/notebooks", as: NotebooksResponseDTO.self), prefix: prefix)
            case .tags:
                return tagLines(try await client.send(.GET, "/tags", as: [TagDTO].self), prefix: prefix)
            }
        } catch {
            return []
        }
    }

    static func noteLines(_ notes: [NoteSummaryDTO], prefix: String) -> [String] {
        lines(notes.map { ($0.id.uuidString, CLIOutput.title($0.title)) }, prefix: prefix)
    }

    static func notebookLines(_ response: NotebooksResponseDTO, prefix: String) -> [String] {
        lines(response.notebooks.map { ($0.name, count($0.noteCount)) }, prefix: prefix)
    }

    static func tagLines(_ tags: [TagDTO], prefix: String) -> [String] {
        lines(tags.map { ($0.name, count($0.noteCount)) }, prefix: prefix)
    }

    private static func count(_ notes: Int) -> String { notes == 1 ? "1 note" : "\(notes) notes" }

    /// Values that can't be typed as one shell word on one line are left out; descriptions are flattened to a line.
    private static func lines(_ candidates: [(value: String, description: String)], prefix: String) -> [String] {
        candidates.compactMap { value, description in
            guard !value.isEmpty, !value.contains(where: \.isNewline), !value.contains("\t"),
                  value.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil || prefix.isEmpty
            else { return nil }
            let line = description.map { $0.isNewline || $0 == "\t" ? " " : $0 }
            return value + "\t" + String(line)
        }
    }
}

private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<Value, Never>?

    var continuation: CheckedContinuation<Value, Never>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func resume(_ value: Value) {
        lock.withLock {
            let continuation = stored
            stored = nil
            return continuation
        }?.resume(returning: value)
    }
}
