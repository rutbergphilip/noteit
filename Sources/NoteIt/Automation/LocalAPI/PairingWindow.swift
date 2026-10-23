import AppKit
import NoteItAPI
import SwiftUI

/// The panel that shows a pairing code (automation spec §6.5). It comes to the front with NoteIt, and the user
/// types its code into the app that asked to pair.
@MainActor
final class PairingWindow {
    static let resultDuration: TimeInterval = 3

    private let model = PairingWindowModel()
    private var panel: NSPanel?
    private var expiryTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    func show(_ request: PairingRequest, deny: @escaping () -> Void, grant: @escaping ([APIScope]) -> Void,
              expire: @escaping () -> Void) {
        closeTask?.cancel()
        model.request = request
        model.granted = Set(request.requestedScopes)
        model.result = nil
        model.deny = deny
        model.grant = grant
        let panel = panel ?? makePanel()
        self.panel = panel
        NSApp.unhide(nil)
        NSApp.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        expiryTask?.cancel()
        let delay = max(0, request.expiresAt.timeIntervalSinceNow) + 0.5
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            expire()
            if self?.model.request?.id == request.id, self?.model.result == nil { self?.close(request.id) }
        }
    }

    func showPaired(_ id: UUID) {
        guard let request = model.request, request.id == id else { return }
        showMessage("Paired with “\(request.clientName)”", for: id)
    }

    func showMessage(_ message: String, for id: UUID) {
        guard model.request?.id == id else { return }
        expiryTask?.cancel()
        model.result = message
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.resultDuration))
            guard !Task.isCancelled else { return }
            self?.close(id)
        }
    }

    func close(_ id: UUID) {
        guard model.request?.id == id else { return }
        expiryTask?.cancel()
        closeTask?.cancel()
        model.request = nil
        model.result = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        panel.title = "Pair an App"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: PairingView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        return panel
    }
}

@MainActor
final class PairingWindowModel: ObservableObject {
    @Published var request: PairingRequest?
    @Published var granted: Set<APIScope> = []
    /// Shown instead of the code once pairing ends.
    @Published var result: String?
    var deny: () -> Void = {}
    var grant: ([APIScope]) -> Void = { _ in }

    /// Scopes are cumulative, so granting one grants the ones below it and taking one away takes the ones above.
    func setScope(_ scope: APIScope, granted isOn: Bool) {
        guard let request, let ceiling = request.requestedScopes.max() else { return }
        let all = APIScope.allCases.filter { ceiling.allows($0) }
        granted = Set(all.filter { isOn ? ($0 <= scope || granted.contains($0)) : ($0 < scope && granted.contains($0)) })
        if granted.isEmpty { granted = [.read] }
        grant(APIScope.normalized(Array(granted)))
    }

    static func sentence(for scope: APIScope) -> String {
        switch scope {
        case .read: "read your notes"
        case .write: "change your notes"
        case .admin: "manage connected apps"
        }
    }

    static func headline(for scopes: [APIScope]) -> String {
        switch scopes.max() ?? .read {
        case .read: "read your notes"
        case .write: "read and change your notes"
        case .admin: "read and change your notes and manage connected apps"
        }
    }

    static func kindName(_ kind: ClientKind) -> String {
        switch kind {
        case .cli: "Command line tool"
        case .extension: "Browser extension"
        case .mcp: "MCP client"
        case .script: "Script"
        }
    }

    /// "482913" → "482 913".
    static func formattedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

private struct PairingView: View {
    @ObservedObject var model: PairingWindowModel
    @State private var showsScopes = false

    var body: some View {
        VStack(spacing: 14) {
            if let request = model.request {
                if let result = model.result {
                    Text(result)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    content(request)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func content(_ request: PairingRequest) -> some View {
        Text("“\(request.clientName)” wants to \(PairingWindowModel.headline(for: Array(model.granted))).")
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 2) {
            Text(PairingWindowModel.kindName(request.kind))
            if let origin = request.origin {
                Text(origin).textSelection(.enabled)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        Text(PairingWindowModel.formattedCode(request.code))
            .font(.system(size: 40, weight: .semibold, design: .monospaced))
            .textSelection(.enabled)
        Text("Type this code in the app that asked to pair.")
            .font(.callout)
            .foregroundStyle(.secondary)
        if request.origin != nil {
            Text("Browser extensions can't manage connected apps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        DisclosureGroup("Allow", isExpanded: $showsScopes) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(APIScope.allCases.filter { (request.requestedScopes.max() ?? .read).allows($0) }, id: \.self) { scope in
                    Toggle(PairingWindowModel.sentence(for: scope).capitalizedFirst, isOn: Binding(
                        get: { model.granted.contains(scope) },
                        set: { model.setScope(scope, granted: $0) }))
                        .disabled(scope == .read)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        HStack {
            Spacer()
            Button("Deny") { model.deny() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
