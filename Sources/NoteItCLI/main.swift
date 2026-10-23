import Foundation
import NoteItAPI

enum CLIExit: Int32 { case ok = 0, error = 1, usage = 2, unreachable = 3, unauthorized = 4, notFound = 5, conflict = 6 }

let status = await CLI(context: .live()).run(Array(CommandLine.arguments.dropFirst()))
exit(status.rawValue)
