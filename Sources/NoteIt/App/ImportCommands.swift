import SwiftUI

struct ImportCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import…") { ImportSheetPresenter.show() }
        }
    }
}
