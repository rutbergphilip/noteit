import Foundation
import NoteItAPI

enum CLIExit: Int32 { case ok = 0, error = 1, usage = 2, unreachable = 3, unauthorized = 4, notFound = 5, conflict = 6 }

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print("noteit \(CLIVersion.current())")
    exit(CLIExit.ok.rawValue)
}
FileHandle.standardError.write(Data("usage: noteit --version\n".utf8))
exit(CLIExit.usage.rawValue)
