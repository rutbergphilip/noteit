import Foundation
import NoteItSync

/// A command line mistake; printed as `noteit: <message>` with exit code 2.
struct CLIUsageError: Error, Equatable {
    var message: String
}

/// One parsed command line: the command name, then what followed it.
struct CLIInvocation: Equatable {
    var command: String
    var positionals: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    /// The last value given for `name`.
    func value(_ name: String) -> String? { options[name]?.last }
    func values(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

enum CLIArguments {
    /// `argv` is everything after the program name, starting with the command. Each command's value options and
    /// flags, plus the global ones, come from `CommandSpec`.
    static func parse(_ argv: [String]) -> Result<CLIInvocation, CLIUsageError> {
        guard let command = argv.first else {
            return .failure(CLIUsageError(message: "No command given. Run noteit help for a list."))
        }
        guard let spec = CommandSpec.named(command) else {
            return .failure(CLIUsageError(message: "Unknown command “\(command)”. Run noteit help for a list."))
        }
        return Result { () throws(CLIUsageError) in
            try parseOptions(Array(argv.dropFirst()), command: command,
                             valueOptions: Set(spec.valueOptions + CommandSpec.globalValueOptions),
                             flags: Set(spec.flags + CommandSpec.globalFlags))
        }
    }

    /// `--name value`, `--name=value`, repeated options, `--` ends options, `-` is a positional.
    /// Names are given without the leading dashes.
    static func parseOptions(_ arguments: [String], command: String, valueOptions: Set<String>,
                             flags: Set<String>) throws(CLIUsageError) -> CLIInvocation {
        var parsed = CLIInvocation(command: command)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                parsed.positionals.append(contentsOf: arguments[index...])
                break
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                parsed.positionals.append(argument)
                continue
            }
            guard argument.hasPrefix("--") else {
                if argument == "-h", flags.contains("help") {
                    parsed.flags.insert("help")
                    continue
                }
                throw CLIUsageError(message: "Unknown option \(argument).")
            }
            let body = argument.dropFirst(2)
            let name: String
            var inline: String?
            if let equals = body.firstIndex(of: "=") {
                name = String(body[..<equals])
                inline = String(body[body.index(after: equals)...])
            } else {
                name = String(body)
            }
            if valueOptions.contains(name) {
                if let inline {
                    parsed.options[name, default: []].append(inline)
                } else {
                    guard index < arguments.count else { throw CLIUsageError(message: "--\(name) needs a value.") }
                    parsed.options[name, default: []].append(arguments[index])
                    index += 1
                }
            } else if flags.contains(name) {
                guard inline == nil else { throw CLIUsageError(message: "--\(name) doesn't take a value.") }
                parsed.flags.insert(name)
            } else {
                throw CLIUsageError(message: "Unknown option --\(name).")
            }
        }
        return parsed
    }
}

enum CLIProfile {
    static let defaultName = "default"

    /// `--profile`, else `NOTEIT_PROFILE`, else `default`.
    static func resolve(flag: String?, environment: [String: String]) throws(CLIUsageError) -> String {
        let name = flag ?? AppEnvironment.nonEmpty("PROFILE", in: environment) ?? defaultName
        try validate(name)
        return name
    }

    static func validate(_ name: String) throws(CLIUsageError) {
        guard isWellFormed(name) else {
            throw CLIUsageError(message: "Profile names are 1 to 32 characters: lowercase letters, digits and hyphens.")
        }
        guard !isReservedForMCP(name) else {
            throw CLIUsageError(message: "The profile name “\(name)” is kept for noteit mcp.")
        }
    }

    static func isWellFormed(_ name: String) -> Bool {
        (1...32).contains(name.count) && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `mcp(-[a-z0-9]+)*`
    static func isReservedForMCP(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.first == "mcp" else { return false }
        return parts.dropFirst().allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }
}
