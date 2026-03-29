import Foundation
struct GitSSHEnvironmentBuilder {
    func environment(privateKeyRef: String?) throws -> (environment: [String: String], cleanupURL: URL?) {
        guard let privateKeyRef else {
            return ([:], nil)
        }

        let keyData = try KeychainSSHKeyStore.load(reference: privateKeyRef)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevVault-\(UUID().uuidString)", isDirectory: false)
        try keyData.write(to: tempURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        let command = "/usr/bin/ssh -i '\(tempURL.path.replacingOccurrences(of: "'", with: "'\\''"))' -o IdentitiesOnly=yes -F /dev/null"
        return (["GIT_SSH_COMMAND": command], tempURL)
    }
}
