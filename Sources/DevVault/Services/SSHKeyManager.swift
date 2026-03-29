import Foundation
struct SSHKeyManager {
    func importKey(from sourceURL: URL, displayName: String?) async throws -> SSHKeyMaterial {
        let privateKeyData = try Data(contentsOf: sourceURL)
        guard !privateKeyData.isEmpty else {
            throw DevVaultError.keyMaterialInvalid
        }

        let publicKeyURL = sourceURL.appendingPathExtension("pub")
        let publicKey: String
        if FileManager.default.fileExists(atPath: publicKeyURL.path) {
            publicKey = (try String(contentsOf: publicKeyURL)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let result = try await CommandRunner.runCollected(
                executable: "ssh-keygen",
                arguments: ["-y", "-f", sourceURL.path]
            )
            guard result.exitCode == 0 else {
                throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            publicKey = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? sourceURL.lastPathComponent
        return SSHKeyMaterial(displayName: name, kind: .imported, publicKey: publicKey, privateKeyData: privateKeyData)
    }

    func generateKey(displayName: String, comment: String?) async throws -> SSHKeyMaterial {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DevVaultError.keyMaterialInvalid
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevVaultGeneratedKeys", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let keyURL = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: keyURL)
            try? FileManager.default.removeItem(at: keyURL.appendingPathExtension("pub"))
        }

        let result = try await CommandRunner.runCollected(
            executable: "ssh-keygen",
            arguments: [
                "-t", "ed25519",
                "-N", "",
                "-C", comment?.nonEmpty ?? trimmedName,
                "-f", keyURL.path,
            ]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let privateKeyData = try Data(contentsOf: keyURL)
        let publicKey = try String(contentsOf: keyURL.appendingPathExtension("pub"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SSHKeyMaterial(displayName: trimmedName, kind: .generated, publicKey: publicKey, privateKeyData: privateKeyData)
    }
}
