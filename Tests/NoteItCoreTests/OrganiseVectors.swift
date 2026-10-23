import Foundation
import XCTest

/// The shared organise test vectors in Vectors/organise-vectors.json, also read by the web app's port.
enum OrganiseVectors {
    static func load() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "organise-vectors", withExtension: "json",
                                                  subdirectory: "Vectors"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func section(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(load()[name] as? [[String: Any]])
    }
}
