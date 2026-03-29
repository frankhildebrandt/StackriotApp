import SwiftData
import SwiftUI

struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let items: Data
    let content: (Data.Element) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let rows = rows(for: Array(items))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    ForEach(row, id: \.self) { item in
                        content(item)
                    }
                    Spacer()
                }
            }
        }
    }

    private func rows(for values: [Data.Element]) -> [[Data.Element]] {
        var rows: [[Data.Element]] = [[]]
        for item in values {
            if rows[rows.count - 1].count == 4 {
                rows.append([item])
            } else {
                rows[rows.count - 1].append(item)
            }
        }
        return rows
    }
}

