import SwiftData
import SwiftUI

struct ActionPillGroup: View {
    let title: String
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            FlowLayout(items: items) { item in
                Button(item) {
                    action(item)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

