import Foundation
import XCTest

/// Portable targets must build for iOS, so they may not reach for macOS-only frameworks.
final class ImportHygieneTests: XCTestCase {
    private static let portableFolders = [
        "Sources/NoteItCore",
        "Sources/NoteItDoc",
        "Tests/Support/NoteItDocTestSupport",
        "Sources/NoteItSync",
        "Sources/NoteItAPI",
    ]

    private static let forbiddenModules = ["AppKit", "Cocoa", "SwiftUI", "UIKit", "Carbon"]
    private static let forbiddenConditions = ["canImport(AppKit)", "os(macOS)"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPortableTargetsImportNoPlatformUIFrameworks() throws {
        var violations: [String] = []
        for folder in Self.portableFolders {
            let url = repoRoot.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            for file in try swiftFiles(in: url) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.components(separatedBy: .newlines) where isViolation(line) {
                    let relative = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                    violations.append("\(relative): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Forbidden imports in portable targets:\n" + violations.joined(separator: "\n"))
    }

    func testScannedFoldersExist() {
        for folder in ["Sources/NoteItCore", "Sources/NoteItSync"] {
            let path = repoRoot.appendingPathComponent(folder).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Missing \(folder)")
        }
    }

    func testDetectsForbiddenLines() {
        XCTAssertTrue(isViolation("import AppKit"))
        XCTAssertTrue(isViolation("@testable import SwiftUI"))
        XCTAssertTrue(isViolation("@preconcurrency import UIKit"))
        XCTAssertTrue(isViolation("#if canImport(AppKit)"))
        XCTAssertTrue(isViolation("#elseif os(macOS)"))
        XCTAssertFalse(isViolation("import Foundation"))
        XCTAssertFalse(isViolation("import CryptoKit"))
    }

    private func isViolation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return false }
        if Self.forbiddenConditions.contains(where: { trimmed.contains($0) }) { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let importIndex = words.firstIndex(of: "import"), importIndex + 1 < words.count else { return false }
        let module = words[importIndex + 1].split(separator: ".").first.map(String.init) ?? ""
        return Self.forbiddenModules.contains(module)
    }

    private func swiftFiles(in folder: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
