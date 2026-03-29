import Foundation
import SwiftData
struct NodeToolingService {
    func runtimeRequirement(
        for worktreeURL: URL,
        defaultVersionSpec: String = AppPreferences.nodeDefaultVersionSpec
    ) -> NodeRuntimeRequirement {
        if let package = readPackageManifest(in: worktreeURL),
           let spec = package.engines?.node?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spec.isEmpty {
            return NodeRuntimeRequirement(
                packageManager: packageManager(in: worktreeURL),
                nodeVersionSpec: spec,
                versionSource: .packageEngines
            )
        }

        let nvmrcURL = worktreeURL.appendingPathComponent(".nvmrc")
        if let value = readVersionSpec(from: nvmrcURL) {
            return NodeRuntimeRequirement(
                packageManager: packageManager(in: worktreeURL),
                nodeVersionSpec: value,
                versionSource: .nvmrc
            )
        }

        let nodeVersionURL = worktreeURL.appendingPathComponent(".node-version")
        if let value = readVersionSpec(from: nodeVersionURL) {
            return NodeRuntimeRequirement(
                packageManager: packageManager(in: worktreeURL),
                nodeVersionSpec: value,
                versionSource: .nodeVersionFile
            )
        }

        return NodeRuntimeRequirement(
            packageManager: packageManager(in: worktreeURL),
            nodeVersionSpec: defaultVersionSpec,
            versionSource: .defaultLTS
        )
    }

    func packageManager(in worktreeURL: URL) -> PackageManagerKind {
        if FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        }
        if FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent("yarn.lock").path) {
            return .yarn
        }
        return .npm
    }

    func discoverScripts(in worktreeURL: URL) -> [String] {
        readPackageManifest(in: worktreeURL)?.scripts.keys.sorted() ?? []
    }

    func installDescriptor(
        for worktree: WorktreeRecord,
        mode: DependencyInstallMode,
        repositoryID: UUID
    ) -> CommandExecutionDescriptor {
        let worktreeURL = URL(fileURLWithPath: worktree.path)
        let packageManager = packageManager(in: worktreeURL)
        let executable: String
        let arguments: [String]

        if packageManager == .pnpm {
            executable = "pnpm"
            arguments = [mode == .install ? "install" : "update"]
        } else if packageManager == .yarn {
            executable = "yarn"
            arguments = [mode == .install ? "install" : "upgrade"]
        } else {
            executable = "npm"
            arguments = [mode == .install ? "install" : "update"]
        }

        return CommandExecutionDescriptor(
            title: "\(mode.displayName) dependencies",
            actionKind: .installDependencies,
            executable: executable,
            arguments: arguments,
            displayCommandLine: nil,
            currentDirectoryURL: worktreeURL,
            repositoryID: repositoryID,
            worktreeID: worktree.id,
            runtimeRequirement: runtimeRequirement(for: worktreeURL),
            stdinText: nil
        )
    }

    private func readPackageManifest(in worktreeURL: URL) -> PackageManifest? {
        let packageURL = worktreeURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PackageManifest.self, from: data)
    }

    private func readVersionSpec(from fileURL: URL) -> String? {
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let cleaned = value
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}
private struct PackageManifest: Decodable {
    let scripts: [String: String]
    let engines: PackageEngines?

    private enum CodingKeys: String, CodingKey {
        case scripts
        case engines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scripts = try container.decodeIfPresent([String: String].self, forKey: .scripts) ?? [:]
        engines = try container.decodeIfPresent(PackageEngines.self, forKey: .engines)
    }
}

private struct PackageEngines: Decodable {
    let node: String?
}
