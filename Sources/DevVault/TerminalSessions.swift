import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class AgentTerminalSession: ObservableObject {
    let runID: UUID
    let view: DevVaultTerminalView

    private var terminationRequested = false
    private let onData: @MainActor (String) -> Void
    private let onTermination: @MainActor (Int32, Bool) -> Void

    init(
        runID: UUID,
        onData: @escaping @MainActor (String) -> Void,
        onTermination: @escaping @MainActor (Int32, Bool) -> Void
    ) {
        self.runID = runID
        self.onData = onData
        self.onTermination = onTermination
        self.view = DevVaultTerminalView(frame: .zero)
        self.view.session = self
        self.view.optionAsMetaKey = true
        self.view.nativeBackgroundColor = .black
        self.view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        self.view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func start(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?
    ) {
        let env = environment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: env,
            currentDirectory: currentDirectory
        )
    }

    func terminate() {
        terminationRequested = true
        view.terminate()
    }

    fileprivate func handleData(_ slice: ArraySlice<UInt8>) {
        let text = String(decoding: Array(slice), as: UTF8.self)
        onData(text)
    }

    fileprivate func handleTermination(_ exitCode: Int32?) {
        onTermination(exitCode ?? 1, terminationRequested)
    }
}

final class DevVaultTerminalView: LocalProcessTerminalView {
    weak var session: AgentTerminalSession?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        session?.handleData(slice)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        session?.handleTermination(exitCode)
    }
}

struct TerminalSessionView: NSViewRepresentable {
    let session: AgentTerminalSession

    func makeNSView(context: Context) -> DevVaultTerminalView {
        session.view
    }

    func updateNSView(_ nsView: DevVaultTerminalView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
