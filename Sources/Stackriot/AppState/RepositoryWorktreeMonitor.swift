import Dispatch
import Foundation
import Darwin

final class RepositoryWorktreeMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.stackriot.repository-worktree-monitor")
    private let debounceInterval: DispatchTimeInterval = .milliseconds(250)
    private let onChange: @Sendable () -> Void
    private var monitoredPaths: [URL] = []
    private var fileDescriptors: [Int32] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingWorkItem: DispatchWorkItem?
    private var isStopped = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func updateObservedPaths(_ paths: [URL]) {
        queue.async { [weak self] in
            self?.updateObservedPathsLocked(paths)
        }
    }

    func stop() {
        queue.sync { [weak self] in
            self?.stopLocked()
        }
    }

    deinit {
        stop()
    }

    private func updateObservedPathsLocked(_ paths: [URL]) {
        guard !isStopped else { return }
        stopSourcesLocked()
        monitoredPaths = paths

        for path in paths {
            guard let source = makeSource(for: path) else { continue }
            sources.append(source)
        }
    }

    private func makeSource(for path: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileDescriptors.append(fd)
        return source
    }

    private func scheduleChange() {
        guard !isStopped else { return }
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fireChange()
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func fireChange() {
        guard !isStopped else { return }
        pendingWorkItem = nil
        onChange()
    }

    private func stopSourcesLocked() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        fileDescriptors.removeAll()
    }

    private func stopLocked() {
        guard !isStopped else { return }
        isStopped = true
        stopSourcesLocked()
    }
}
