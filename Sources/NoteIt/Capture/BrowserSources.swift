import Foundation

/// AppleScript sources that read the front tab's URL and title from scriptable browsers.
enum BrowserSources {
    private static let safariFamily: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    private static let chromiumFamily: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ]

    static let timeoutSeconds = 2

    static let supportedBundleIDs: Set<String> = safariFamily.union(chromiumFamily)

    /// A script whose result is "URL\nTITLE", or an empty string when the browser has no usable window.
    static func appleScript(forBundleID bundleID: String) -> String? {
        if safariFamily.contains(bundleID) {
            return script(bundleID: bundleID, tab: "current tab", titleProperty: "name")
        }
        if chromiumFamily.contains(bundleID) {
            return script(bundleID: bundleID, tab: "active tab", titleProperty: "title")
        }
        return nil
    }

    static func parse(_ output: String) -> (url: URL?, title: String?) {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let firstLine: Substring
        let rest: Substring
        if let newline = normalized.firstIndex(of: "\n") {
            firstLine = normalized[..<newline]
            rest = normalized[normalized.index(after: newline)...]
        } else {
            firstLine = Substring(normalized)
            rest = ""
        }
        let urlText = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlText.isEmpty ? nil : CaptureFormatter.linkableURL(URL(string: urlText))
        let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, title.isEmpty ? nil : title)
    }

    private static func script(bundleID: String, tab: String, titleProperty: String) -> String {
        let id = bundleID.replacingOccurrences(of: "\"", with: "")
        return """
        with timeout of \(timeoutSeconds) seconds
            if application id "\(id)" is running then
                tell application id "\(id)"
                    if (count of windows) is 0 then return ""
                    set pageURL to ""
                    set pageTitle to ""
                    try
                        set rawURL to URL of \(tab) of front window
                        if rawURL is not missing value then set pageURL to rawURL as text
                    on error number errorNumber
                        if errorNumber is -1712 then error number errorNumber
                    end try
                    try
                        set rawTitle to \(titleProperty) of \(tab) of front window
                        if rawTitle is not missing value then set pageTitle to rawTitle as text
                    on error number errorNumber
                        if errorNumber is -1712 then error number errorNumber
                    end try
                    return pageURL & linefeed & pageTitle
                end tell
            end if
        end timeout
        return ""
        """
    }
}
