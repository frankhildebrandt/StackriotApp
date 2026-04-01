import Foundation

final class AgentRawLogArchiveService {
    private let fileManager: FileManager
    private let rootDirectoryProvider: () -> URL

    init(
        fileManager: FileManager = .default,
        rootDirectoryProvider: @escaping () -> URL = { AppPaths.rawLogsDirectory }
    ) {
        self.fileManager = fileManager
        self.rootDirectoryProvider = rootDirectoryProvider
    }

    func createRecord(
        runID: UUID,
        descriptor: CommandExecutionDescriptor,
        repository: ManagedRepository,
        worktree: WorktreeRecord?,
        startedAt: Date,
        initialOutput: String
    ) throws -> AgentRawLogRecord {
        guard let agentTool = descriptor.agentTool else {
            throw StackriotError.commandFailed("RAW log archiving is only available for explicit AI agent runs.")
        }

        let directory = try makeLogDirectory(
            startedAt: startedAt,
            agentTool: agentTool,
            repositoryName: repository.displayName,
            title: descriptor.title,
            runID: runID
        )
        let fileExtension = fileExtension(for: descriptor.outputInterpreter)
        let logURL = directory.appendingPathComponent("raw.\(fileExtension)", isDirectory: false)
        let initialData = Data(initialOutput.utf8)
        fileManager.createFile(atPath: logURL.path, contents: initialData)

        let record = AgentRawLogRecord(
            runID: runID,
            repositoryID: repository.id,
            worktreeID: worktree?.id,
            projectID: repository.project?.id,
            projectName: repository.project?.name,
            repositoryName: repository.displayName,
            worktreeBranchName: worktree?.branchName,
            agentTool: agentTool,
            title: descriptor.title,
            promptText: descriptor.initialPrompt,
            startedAt: startedAt,
            logFilePath: logURL.path,
            status: .running
        )

        record.fileSize = try currentFileSize(at: logURL)
        return record
    }

    func append(_ chunk: String, to record: AgentRawLogRecord) throws {
        guard !chunk.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: record.logFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(chunk.utf8))
        record.fileSize = try currentFileSize(at: record.logFileURL)
    }

    func finalize(_ record: AgentRawLogRecord, endedAt: Date, status: RunStatusKind) throws {
        record.endedAt = endedAt
        record.durationSeconds = max(0, endedAt.timeIntervalSince(record.startedAt))
        record.status = status
        record.fileSize = try currentFileSize(at: record.logFileURL)
    }

    func readContents(of record: AgentRawLogRecord) throws -> String {
        try String(contentsOf: record.logFileURL, encoding: .utf8)
    }

    func delete(_ record: AgentRawLogRecord) throws {
        let logURL = record.logFileURL
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.removeItem(at: logURL)
        }

        let directoryURL = logURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directoryURL.path) {
            let remainingEntries = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
            if remainingEntries.isEmpty {
                try fileManager.removeItem(at: directoryURL)
            }
        }
    }

    private func makeLogDirectory(
        startedAt: Date,
        agentTool: AIAgentTool,
        repositoryName: String,
        title: String,
        runID: UUID
    ) throws -> URL {
        let root = rootDirectoryProvider()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = Self.directoryTimestampFormatter.string(from: startedAt)
        let directoryName = [
            stamp,
            AppPaths.sanitizedPathComponent(agentTool.displayName),
            AppPaths.sanitizedPathComponent(repositoryName),
            AppPaths.sanitizedPathComponent(title),
            runID.uuidString.lowercased(),
        ].joined(separator: "-")
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func fileExtension(for interpreter: RunOutputInterpreterKind?) -> String {
        interpreter == nil ? "log" : "jsonl"
    }

    private func currentFileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static let directoryTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
