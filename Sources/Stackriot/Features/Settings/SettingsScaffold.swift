import AppKit
import SwiftUI

struct SettingsFormPage<Content: View>: View {
    let category: SettingsCategory
    let content: Content

    init(category: SettingsCategory, @ViewBuilder content: () -> Content) {
        self.category = category
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(category: category)
            Divider()
            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsScrollPage<Content: View>: View {
    let category: SettingsCategory
    let content: Content

    init(category: SettingsCategory, @ViewBuilder content: () -> Content) {
        self.category = category
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsPageHeader(category: category)
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsPageHeader: View {
    let category: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(category.title)
                    .font(.largeTitle.weight(.semibold))
            } icon: {
                Image(systemName: category.symbolName)
                    .foregroundStyle(.tint)
            }

            Text(category.shortDescription)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}
