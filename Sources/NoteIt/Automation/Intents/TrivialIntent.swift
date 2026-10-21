import AppIntents

struct TrivialIntent: AppIntent {
    static var title: LocalizedStringResource = "Show NoteIt"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowRouter.showMainWindow()
        return .result()
    }
}
