import SwiftUI

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .accentColor
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }
            .padding(.bottom, 4)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tint)
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
