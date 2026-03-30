import AppKit
import Foundation
import SwiftData

extension AppModel {
    func copyRawLogContents(_ record: AgentRawLogRecord) {
        do {
            let contents = try services.rawLogArchive.readContents(of: record)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
        } catch {
            pendingErrorMessage = "RAW log could not be copied: \(error.localizedDescription)"
        }
    }

    func openRawLogExternally(_ record: AgentRawLogRecord) {
        NSWorkspace.shared.open(record.logFileURL)
    }

    func revealRawLogInFinder(_ record: AgentRawLogRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.logFileURL])
    }

    func rawLogContents(_ record: AgentRawLogRecord) throws -> String {
        try services.rawLogArchive.readContents(of: record)
    }

    func deleteRawLog(_ record: AgentRawLogRecord, in modelContext: ModelContext) {
        guard record.status != .running else {
            pendingErrorMessage = "Active RAW logs can only be deleted after the run has finished."
            return
        }

        do {
            try services.rawLogArchive.delete(record)
            if let runID = record.runID {
                rawLogRecordIDsByRunID.removeValue(forKey: runID)
            }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            pendingErrorMessage = "RAW log could not be deleted: \(error.localizedDescription)"
        }
    }
}
