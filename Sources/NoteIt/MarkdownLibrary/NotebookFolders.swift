import Foundation
import NoteItCore

/// Notebook folders of a Markdown library (spec §3.4): each folder up to 4 levels deep is a notebook named after
/// it, with the rest of its record in `.noteit-notebook.json`.
enum NotebookFolders {
    static let maxDepth = NotebookTree.maxDepth
    static let fileName = ".noteit-notebook.json"
    /// The keys NoteIt writes. `revision` and `modifiedAt` are sync state and stay in `library.json`.
    static let ownedKeys: Set<String> = ["id", "symbol", "colorHex", "sortIndex", "defaultTemplateID", "parent"]
    /// Never kept, even as unknown keys: the name is the folder's, and a share never travels with the folder.
    static let forbiddenKeys: Set<String> = ["name", "spaceID", "revision", "modifiedAt"]
    static let defaultSymbol = "folder"
    static let defaultColor = "#0A84FF"

    /// Whether a folder with this name can be a notebook: not hidden, not `_attachments` or another `_` folder.
    static func isNotebookFolderName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.hasPrefix("_") && name != "node_modules" && !name.isEmpty
    }

    /// Reads `.noteit-notebook.json`, keeping every key except `name` and the forbidden ones. The name is the
    /// folder's. A folder without the file (or with a damaged one) gets a new id and the defaults new notebooks
    /// use; `raw` is then empty, or the damaged file's readable keys.
    static func read(_ folder: URL) throws -> (notebook: Notebook, raw: [String: Any]) {
        let file = folder.appendingPathComponent(fileName)
        var raw: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        for key in forbiddenKeys { raw[key] = nil }
        let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let notebook = Notebook(
            id: id,
            name: folder.lastPathComponent,
            symbol: raw["symbol"] as? String ?? defaultSymbol,
            colorHex: raw["colorHex"] as? String ?? defaultColor,
            sortIndex: (raw["sortIndex"] as? NSNumber)?.intValue ?? 0,
            defaultTemplateID: (raw["defaultTemplateID"] as? String).flatMap(UUID.init(uuidString:)),
            parent: (raw["parent"] as? String).flatMap(UUID.init(uuidString:))
        )
        return (notebook, raw)
    }

    /// Patches only the keys NoteIt owns into `raw` and writes it atomically; never writes `name` or `spaceID`.
    static func write(_ notebook: Notebook, raw: [String: Any], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data(for: notebook, raw: raw).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    static func data(for notebook: Notebook, raw: [String: Any]) throws -> Data {
        var object = raw
        for key in forbiddenKeys { object[key] = nil }
        object["id"] = notebook.id.uuidString
        object["symbol"] = notebook.symbol
        object["colorHex"] = notebook.colorHex
        object["sortIndex"] = notebook.sortIndex
        object["defaultTemplateID"] = notebook.defaultTemplateID?.uuidString ?? NSNull()
        object["parent"] = notebook.parent?.uuidString ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The folder name for a notebook, made unique among `taken` (lowercased sibling names).
    static func folderName(for notebook: Notebook, taken: inout Set<String>) -> String {
        var name = ExportNaming.sanitized(notebook.name, fallback: "Notebook")
        while name.hasPrefix("_") { name.removeFirst() }
        name = MarkdownPathIndex.fitting(name, maxBytes: MarkdownPathIndex.maxStemBytes)
        if name.isEmpty || name.lowercased() == "node_modules" { name = "Notebook" }
        return ExportNaming.unique(name, extension: "", taken: &taken)
    }

    /// Content-relative folder paths for every notebook, parents first, siblings in sort order. Notebooks deeper
    /// than `maxDepth` (which NoteIt doesn't create) get their deepest allowed ancestor's folder. `existing` keeps
    /// a notebook's recorded folder name while its notebook name still matches it.
    static func layout(_ notebooks: [Notebook], existing: [UUID: String]) -> [UUID: String] {
        let byID = Dictionary(notebooks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [UUID?: [Notebook]] = [:]
        for notebook in notebooks {
            let parent = notebook.parent.flatMap { byID[$0] != nil ? $0 : nil }
            children[parent, default: []].append(notebook)
        }
        var result: [UUID: String] = [:]
        func place(_ parent: UUID?, path: String, depth: Int) {
            let siblings = (children[parent] ?? []).sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
            var taken = Set<String>()
            var named: [(Notebook, String)] = []
            // Keep recorded names first so an unrelated sibling never takes over a folder.
            for notebook in siblings {
                if let recorded = existing[notebook.id], MarkdownPathIndex.folder(of: recorded) == path,
                   matches(recorded: (recorded as NSString).lastPathComponent, notebook: notebook),
                   !taken.contains(((recorded as NSString).lastPathComponent).lowercased()) {
                    let name = (recorded as NSString).lastPathComponent
                    taken.insert(name.lowercased())
                    named.append((notebook, name))
                }
            }
            for notebook in siblings where !named.contains(where: { $0.0.id == notebook.id }) {
                named.append((notebook, folderName(for: notebook, taken: &taken)))
            }
            for (notebook, name) in named {
                if depth > maxDepth {
                    result[notebook.id] = path
                    place(notebook.id, path: path, depth: depth + 1)
                } else {
                    let full = path.isEmpty ? name : path + "/" + name
                    result[notebook.id] = full
                    place(notebook.id, path: full, depth: depth + 1)
                }
            }
        }
        place(nil, path: "", depth: 1)
        return result
    }

    /// Whether a recorded folder name still belongs to the notebook (its name sanitized, or with a ` 2` suffix), case included.
    private static func matches(recorded: String, notebook: Notebook) -> Bool {
        let base = MarkdownPathIndex.fitting(ExportNaming.sanitized(notebook.name, fallback: "Notebook"),
                                             maxBytes: MarkdownPathIndex.maxStemBytes)
        let name = recorded
        if name == base { return true }
        guard name.hasPrefix(base + " ") else { return false }
        return Int(name.dropFirst(base.count + 1)) != nil
    }
}
