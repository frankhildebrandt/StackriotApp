import SwiftUI

struct AsyncActionLabel: View {
    let title: String
    let systemImage: String
    let isRunning: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
        }
    }
}

struct AsyncIconLabel: View {
    let systemImage: String
    let isRunning: Bool

    var body: some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: systemImage)
        }
    }
}
