import Foundation

struct CaptureSource: Equatable {
    var appName: String
    var bundleID: String?
    var windowTitle: String?
    var pageURL: URL?
    var pageTitle: String?
    var documentURL: URL?
}

struct CapturedSelection: Equatable {
    var text: String
    var source: CaptureSource
}
