import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class AgentTerminalSession: ObservableObject {
    let runID: UUID
    let view: StackriotTerminalView

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
        self.view = StackriotTerminalView(frame: .zero)
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

    func forceTerminate() {
        terminationRequested = true

        let shellPID = view.process.shellPid
        if shellPID != 0 {
            _ = kill(-shellPID, SIGKILL)
            _ = kill(shellPID, SIGKILL)
        }

        view.terminate()
    }

    func send(text: String) {
        view.process.send(data: ArraySlice(text.utf8))
    }

    func runningDescendantProcesses() async -> [String] {
        let rootPID = Int(view.process.shellPid)
        guard rootPID > 0 else { return [] }

        do {
            let result = try await CommandRunner.runCollected(
                executable: "ps",
                arguments: ["-axo", "ppid=,pid=,comm="]
            )
            return Self.parseDescendantProcesses(from: result.stdout, rootPID: rootPID)
        } catch {
            return []
        }
    }

    fileprivate func handleData(_ slice: ArraySlice<UInt8>) {
        let text = String(decoding: Array(slice), as: UTF8.self)
        onData(text)
    }

    fileprivate func handleTermination(_ exitCode: Int32?) {
        onTermination(exitCode ?? 1, terminationRequested)
    }

    private static func parseDescendantProcesses(from output: String, rootPID: Int) -> [String] {
        struct ProcessEntry {
            let parentPID: Int
            let pid: Int
            let command: String
        }

        let entries = output.split(separator: "\n").compactMap { line -> ProcessEntry? in
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3,
                  let parentPID = Int(parts[0]),
                  let pid = Int(parts[1]) else {
                return nil
            }

            return ProcessEntry(parentPID: parentPID, pid: pid, command: String(parts[2]))
        }

        let childrenByParent = Dictionary(grouping: entries, by: \.parentPID)
        var queue = [rootPID]
        var visited = Set<Int>([rootPID])
        var processNames: [String] = []

        while !queue.isEmpty {
            let parentPID = queue.removeFirst()
            for child in childrenByParent[parentPID] ?? [] {
                guard visited.insert(child.pid).inserted else { continue }
                queue.append(child.pid)
                processNames.append(URL(fileURLWithPath: child.command).lastPathComponent)
            }
        }

        return Array(NSOrderedSet(array: processNames)) as? [String] ?? processNames
    }
}

final class StackriotTerminalView: LocalProcessTerminalView {
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

final class TerminalSessionContainerView: NSView {
    private weak var hostedTerminalView: StackriotTerminalView?

    func host(_ terminalView: StackriotTerminalView) {
        guard hostedTerminalView !== terminalView else { return }

        hostedTerminalView?.removeFromSuperview()
        hostedTerminalView = terminalView

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

struct TerminalSessionView: NSViewRepresentable {
    let session: AgentTerminalSession

    func makeNSView(context: Context) -> TerminalSessionContainerView {
        let container = TerminalSessionContainerView(frame: .zero)
        container.host(session.view)
        return container
    }

    func updateNSView(_ nsView: TerminalSessionContainerView, context: Context) {
        nsView.host(session.view)
        DispatchQueue.main.async {
            session.view.window?.makeFirstResponder(session.view)
        }
    }
}
