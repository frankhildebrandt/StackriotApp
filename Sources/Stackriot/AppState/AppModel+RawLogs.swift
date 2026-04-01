import AppKit
import Foundation
import SwiftData

extension AppModel {
    func copyRawLogContents(_ record: AgentRawLogRecord) {
        Task {
            do {
                let contents = try await rawLogContents(record)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(contents, forType: .string)
            } catch {
                pendingErrorMessage = "RAW log could not be copied: \(error.localizedDescription)"
            }
        }
    }

    func openRawLogExternally(_ record: AgentRawLogRecord) {
        NSWorkspace.shared.open(record.logFileURL)
    }

    func revealRawLogInFinder(_ record: AgentRawLogRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.logFileURL])
    }

    func rawLogContents(_ record: AgentRawLogRecord) async throws -> String {
        let logURL = record.logFileURL
        return try await Task.detached(priority: .utility) {
            try String(contentsOf: logURL, encoding: .utf8)
        }.value
    }

    func deleteRawLog(_ record: AgentRawLogRecord, in modelContext: ModelContext) async {
        guard record.status != .running else {
            pendingErrorMessage = "Active RAW logs can only be deleted after the run has finished."
            return
        }

        let logURL = record.logFileURL
        let runID = record.runID

        do {
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
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
            }.value

            if let runID {
                rawLogRecordIDsByRunID.removeValue(forKey: runID)
                rawLogFileURLsByRunID.removeValue(forKey: runID)
                await rawLogAppendCoordinator.close(runID: runID)
            }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            pendingErrorMessage = "RAW log could not be deleted: \(error.localizedDescription)"
        }
    }
}
