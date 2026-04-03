import SwiftUI

extension View {
    /// Adds **Command + Return** as an additional keyboard shortcut that triggers `action`.
    ///
    /// Use this modifier on or near the primary `.borderedProminent` button in a sheet to allow
    /// keyboard-centric users to confirm dialogs without moving focus first.
    /// The existing Return / `.defaultAction` shortcut is not affected.
    ///
    /// - Parameters:
    ///   - disabled: When `true` the shortcut is inactive, mirroring the primary button's disabled state.
    ///   - action: The action to perform — should match the primary button's action.
    func commandEnterAction(disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        background(
            Button("") { action() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(disabled)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }
}
