import Foundation

public protocol SyncCipher: Sendable {
    func seal(_ plain: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}
