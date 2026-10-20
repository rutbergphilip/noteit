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

    private static let forbiddenModules = ["AppKit", "Cocoa", "SwiftUI", "UIKit", "Carbon", "Network"]
    /// Modules one portable target may import although the others may not. Automation's Local API server needs Network.
    private static let allowedPerFolder: [String: Set<String>] = ["Sources/NoteItAPI": ["Network"]]
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
            let allowed = Self.allowedPerFolder[folder] ?? []
            for file in try swiftFiles(in: url) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.components(separatedBy: .newlines) where isViolation(line, allowing: allowed) {
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
        XCTAssertTrue(isViolation("import struct AppKit.NSColor"))
        XCTAssertTrue(isViolation("#if canImport(AppKit)"))
        XCTAssertTrue(isViolation("#elseif os(macOS)"))
        XCTAssertFalse(isViolation("import Foundation"))
        XCTAssertFalse(isViolation("import CryptoKit"))
    }

    func testNetworkIsAllowedOnlyWhereListed() {
        XCTAssertTrue(isViolation("import Network"))
        XCTAssertFalse(isViolation("import Network", allowing: Self.allowedPerFolder["Sources/NoteItAPI"] ?? []))
        XCTAssertTrue(isViolation("import AppKit", allowing: Self.allowedPerFolder["Sources/NoteItAPI"] ?? []))
        XCTAssertNil(Self.allowedPerFolder["Sources/NoteItCore"])
    }

    private func isViolation(_ line: String, allowing allowed: Set<String> = []) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return false }
        if Self.forbiddenConditions.contains(where: { trimmed.contains($0) }) { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let importIndex = words.firstIndex(of: "import") else { return false }
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"]
        guard let path = words[(importIndex + 1)...].first(where: { !kinds.contains($0) }) else { return false }
        let module = path.split(separator: ".").first.map(String.init) ?? ""
        return Self.forbiddenModules.contains(module) && !allowed.contains(module)
    }

    private func swiftFiles(in folder: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
