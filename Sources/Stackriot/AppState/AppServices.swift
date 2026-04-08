import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog
import UserNotifications

enum AppNotificationAuthorizationState: Sendable, Equatable {
    case authorized
    case denied
    case unsupported
}

enum AppNotificationKind: String, Sendable, Equatable {
    case success
    case failure
}

enum AppNotificationDeliveryResult: Sendable, Equatable {
    case delivered
    case skipped(AppNotificationAuthorizationState)
    case failed
}

struct AppNotificationRequest: Sendable, Equatable {
    let identifier: String
    let title: String
    let subtitle: String?
    let body: String
    let userInfo: [String: String]
    let kind: AppNotificationKind

    init(
        identifier: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: String] = [:],
        kind: AppNotificationKind = .success
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.body = body
        self.userInfo = userInfo
        self.kind = kind
    }
}

protocol AppNotificationServing: Sendable {
    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState

    @discardableResult
    func deliver(_ request: AppNotificationRequest) async -> AppNotificationDeliveryResult
}

protocol UserNotificationCentering: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    func register(_ configuration: QuickIntentHotkeyConfiguration, handler: @escaping @MainActor () -> Void)
    func unregister()
}

struct QuickIntentCapture: Sendable, Equatable {
    let text: String
    let source: QuickIntentCaptureSource
    let sourceLabel: String
    let accessibilityAvailable: Bool
    let accessibilityHint: String?
}

protocol QuickIntentContextServing: Sendable {
    @MainActor
    func captureCurrentContext() -> QuickIntentCapture

    @MainActor
    func captureContext(from url: URL) throws -> QuickIntentCapture
}

struct SystemUserNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

@MainActor
final class CarbonGlobalHotKeyManager: GlobalHotKeyRegistering {
    private static let signature = OSType(0x53545254)
    private static var installedHandler = false
    private static var activeHandlers: [UInt32: @MainActor () -> Void] = [:]

    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyIDValue: UInt32 = 1

    func register(_ configuration: QuickIntentHotkeyConfiguration, handler: @escaping @MainActor () -> Void) {
        unregister()
        guard configuration.isEnabled else { return }

        Self.installHandlerIfNeeded()
        Self.activeHandlers[hotKeyIDValue] = handler

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKeyIDValue)
        let status = RegisterEventHotKey(
            UInt32(configuration.keyCode),
            carbonModifiers(from: configuration.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            Self.activeHandlers.removeValue(forKey: hotKeyIDValue)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        Self.activeHandlers.removeValue(forKey: hotKeyIDValue)
    }

    private func carbonModifiers(from modifiers: QuickIntentModifierSet) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func installHandlerIfNeeded() {
        guard !installedHandler else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            nil
        )
        installedHandler = true
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, _ in
        guard let eventRef else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }
        if let handler = activeHandlers[hotKeyID.id] {
            Task { @MainActor in
                handler()
            }
        }
        return noErr
    }
}

struct QuickIntentContextService: QuickIntentContextServing {
    @MainActor
    func captureCurrentContext() -> QuickIntentCapture {
        let accessibilityTrusted = AXIsProcessTrusted()
        if accessibilityTrusted, let rawSelectedText = selectedText(), let selectedText = rawSelectedText.nonEmpty {
            return QuickIntentCapture(
                text: selectedText,
                source: .accessibilitySelection,
                sourceLabel: "Markierung aus aktiver App",
                accessibilityAvailable: true,
                accessibilityHint: nil
            )
        }

        if let rawClipboardText = clipboardText(), let clipboardText = rawClipboardText.nonEmpty {
            return QuickIntentCapture(
                text: clipboardText,
                source: .clipboard,
                sourceLabel: "Zwischenablage",
                accessibilityAvailable: accessibilityTrusted,
                accessibilityHint: accessibilityTrusted ? nil : "Markierungstext ist nur mit erteilter Bedienungshilfe-Berechtigung verfuegbar."
            )
        }

        return QuickIntentCapture(
            text: "",
            source: .empty,
            sourceLabel: accessibilityTrusted ? "Keine Quelle" : "Keine Quelle (nur Clipboard verfuegbar)",
            accessibilityAvailable: accessibilityTrusted,
            accessibilityHint: accessibilityTrusted ? nil : "Markierungstext ist nur mit erteilter Bedienungshilfe-Berechtigung verfuegbar."
        )
    }

    @MainActor
    func captureContext(from url: URL) throws -> QuickIntentCapture {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw StackriotError.commandFailed("Quick-Intent-URL ist ungueltig.")
        }
        guard url.host?.caseInsensitiveCompare("quick-intent") == .orderedSame else {
            throw StackriotError.commandFailed("Unbekannter Stackriot-Link: \(url.absoluteString)")
        }

        let items = components.queryItems ?? []
        if let rawText = items.first(where: { $0.name == "text" })?.value {
            let text = rawText.removingPercentEncoding ?? rawText
            if let nonEmptyText = text.nonEmpty {
                return QuickIntentCapture(
                    text: nonEmptyText,
                    source: .sharedText,
                    sourceLabel: "Geteilter Text",
                    accessibilityAvailable: AXIsProcessTrusted(),
                    accessibilityHint: nil
                )
            }
        }

        if let rawPath = items.first(where: { $0.name == "file" })?.value {
            let path = rawPath.removingPercentEncoding ?? rawPath
            let fileURL = URL(fileURLWithPath: path)
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            return QuickIntentCapture(
                text: contents,
                source: .sharedFile,
                sourceLabel: "Geteilte Datei",
                accessibilityAvailable: AXIsProcessTrusted(),
                accessibilityHint: nil
            )
        }

        throw StackriotError.commandFailed("Quick-Intent-Link enthaelt weder `text` noch `file`.")
    }

    @MainActor
    private func clipboardText() -> String? {
        if let string = NSPasteboard.general.string(forType: .string)?.nonEmpty {
            return string
        }

        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return nil
        }

        for url in urls {
            guard url.isFileURL else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8), let nonEmptyText = text.nonEmpty {
                return nonEmptyText
            }
        }

        return nil
    }

    @MainActor
    private func selectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        let appStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppValue)
        guard appStatus == .success, let focusedApp = focusedAppValue else { return nil }

        var focusedElementValue: CFTypeRef?
        let elementStatus = AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue)
        guard elementStatus == .success, let focusedElement = focusedElementValue else { return nil }

        var selectedTextValue: CFTypeRef?
        let textStatus = AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        guard textStatus == .success else { return nil }
        return selectedTextValue as? String
    }
}

actor AppNotificationService: AppNotificationServing {
    private let center: any UserNotificationCentering
    private let logger = Logger(subsystem: "Stackriot", category: "notifications")
    private var cachedAuthorizationState: AppNotificationAuthorizationState?

    init(center: any UserNotificationCentering = SystemUserNotificationCenter()) {
        self.center = center
    }

    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState {
        await resolveAuthorizationState(requestIfNeeded: true)
    }

    @discardableResult
    func deliver(_ request: AppNotificationRequest) async -> AppNotificationDeliveryResult {
        let authorization = await resolveAuthorizationState(requestIfNeeded: true)
        guard authorization == .authorized else {
            if authorization == .denied {
                logger.notice("Skipping notification delivery because authorization was denied.")
            }
            return .skipped(authorization)
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        if let subtitle = request.subtitle {
            content.subtitle = subtitle
        }
        content.body = request.body
        content.sound = .default
        content.userInfo = request.userInfo
        content.threadIdentifier = request.kind.rawValue

        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: request.identifier,
                    content: content,
                    trigger: nil
                )
            )
            return .delivered
        } catch {
            logger.error("Failed to deliver notification: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func resolveAuthorizationState(requestIfNeeded: Bool) async -> AppNotificationAuthorizationState {
        if let cachedAuthorizationState, cachedAuthorizationState != .unsupported {
            return cachedAuthorizationState
        }

        let authorizationStatus = await center.authorizationStatus()
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            cachedAuthorizationState = .authorized
            return .authorized
        case .denied:
            cachedAuthorizationState = .denied
            return .denied
        case .notDetermined:
            guard requestIfNeeded else {
                return .denied
            }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let resolved: AppNotificationAuthorizationState = granted ? .authorized : .denied
                cachedAuthorizationState = resolved
                return resolved
            } catch {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                cachedAuthorizationState = .denied
                return .denied
            }
        @unknown default:
            logger.error("Encountered unsupported notification authorization status.")
            cachedAuthorizationState = .unsupported
            return .unsupported
        }
    }
}

@MainActor
struct AppServices {
    let repositoryManager: RepositoryManager
    let worktreeManager: WorktreeManager
    let gitHubCLIService: GitHubCLIService
    let jiraCloudService: JiraCloudService
    let aiProviderService: AIProviderService
    let ideManager: IDEManager
    let sshKeyManager: SSHKeyManager
    let agentManager: AIAgentManager
    let nodeTooling: NodeToolingService
    let nodeRuntimeManager: NodeRuntimeManager
    let localToolManager: LocalToolManager
    let makeTooling: MakeToolingService
    let worktreeStatusService: WorktreeStatusService
    let devToolDiscovery: DevToolDiscoveryService
    let runConfigurationDiscovery: RunConfigurationDiscoveryService
    let devContainerService: DevContainerService
    let mcpServerManager: MCPServerManager
    let acpDiscoveryService: ACPAgentDiscoveryService
    let rawLogArchive: AgentRawLogArchiveService
    let notificationService: any AppNotificationServing
    let quickIntentContextService: any QuickIntentContextServing
    let globalHotKeyManager: any GlobalHotKeyRegistering

    init(
        repositoryManager: RepositoryManager = RepositoryManager(),
        worktreeManager: WorktreeManager = WorktreeManager(),
        gitHubCLIService: GitHubCLIService = GitHubCLIService(),
        jiraCloudService: JiraCloudService = JiraCloudService(),
        aiProviderService: AIProviderService = AIProviderService(),
        ideManager: IDEManager = IDEManager(),
        sshKeyManager: SSHKeyManager = SSHKeyManager(),
        agentManager: AIAgentManager? = nil,
        nodeTooling: NodeToolingService = NodeToolingService(),
        nodeRuntimeManager: NodeRuntimeManager = NodeRuntimeManager(),
        localToolManager: LocalToolManager? = nil,
        makeTooling: MakeToolingService = MakeToolingService(),
        worktreeStatusService: WorktreeStatusService = WorktreeStatusService(),
        devToolDiscovery: DevToolDiscoveryService = DevToolDiscoveryService(),
        runConfigurationDiscovery: RunConfigurationDiscoveryService = RunConfigurationDiscoveryService(),
        devContainerService: DevContainerService? = nil,
        mcpServerManager: MCPServerManager = MCPServerManager(),
        acpDiscoveryService: ACPAgentDiscoveryService = ACPAgentDiscoveryService(),
        rawLogArchive: AgentRawLogArchiveService = AgentRawLogArchiveService(),
        notificationService: any AppNotificationServing = AppNotificationService(),
        quickIntentContextService: any QuickIntentContextServing = QuickIntentContextService(),
        globalHotKeyManager: any GlobalHotKeyRegistering = CarbonGlobalHotKeyManager()
    ) {
        let localToolManager = localToolManager ?? LocalToolManager(nodeRuntimeManager: nodeRuntimeManager)
        let agentManager = agentManager ?? AIAgentManager(localToolManager: localToolManager)

        self.repositoryManager = repositoryManager
        self.worktreeManager = worktreeManager
        self.gitHubCLIService = gitHubCLIService
        self.jiraCloudService = jiraCloudService
        self.aiProviderService = aiProviderService
        self.ideManager = ideManager
        self.sshKeyManager = sshKeyManager
        self.agentManager = agentManager
        self.nodeTooling = nodeTooling
        self.nodeRuntimeManager = nodeRuntimeManager
        self.localToolManager = localToolManager
        self.makeTooling = makeTooling
        self.worktreeStatusService = worktreeStatusService
        self.devToolDiscovery = devToolDiscovery
        self.runConfigurationDiscovery = runConfigurationDiscovery
        self.devContainerService = devContainerService ?? DevContainerService(localToolManager: localToolManager)
        self.mcpServerManager = mcpServerManager
        self.acpDiscoveryService = acpDiscoveryService
        self.rawLogArchive = rawLogArchive
        self.notificationService = notificationService
        self.quickIntentContextService = quickIntentContextService
        self.globalHotKeyManager = globalHotKeyManager
    }

    static let production = AppServices(
        repositoryManager: RepositoryManager(),
        worktreeManager: WorktreeManager(),
        gitHubCLIService: GitHubCLIService(),
        jiraCloudService: JiraCloudService(),
        aiProviderService: AIProviderService(),
        ideManager: IDEManager(),
        sshKeyManager: SSHKeyManager(),
        agentManager: nil,
        nodeTooling: NodeToolingService(),
        nodeRuntimeManager: NodeRuntimeManager(),
        localToolManager: nil,
        makeTooling: MakeToolingService(),
        worktreeStatusService: WorktreeStatusService(),
        devToolDiscovery: DevToolDiscoveryService(),
        runConfigurationDiscovery: RunConfigurationDiscoveryService(),
        devContainerService: nil,
        mcpServerManager: MCPServerManager(),
        acpDiscoveryService: ACPAgentDiscoveryService(),
        rawLogArchive: AgentRawLogArchiveService(),
        notificationService: AppNotificationService(),
        quickIntentContextService: QuickIntentContextService(),
        globalHotKeyManager: CarbonGlobalHotKeyManager()
    )
}

extension QuickIntentHotkeyConfiguration {
    var displayString: String {
        let modifierParts = [
            modifiers.contains(.command) ? "Cmd" : nil,
            modifiers.contains(.option) ? "Opt" : nil,
            modifiers.contains(.control) ? "Ctrl" : nil,
            modifiers.contains(.shift) ? "Shift" : nil,
        ].compactMap { $0 }

        return (modifierParts + [Self.keyLabel(for: keyCode)]).joined(separator: " + ")
    }

    static func keyLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 49: "Space"
        case 36: "Return"
        default:
            "Key \(keyCode)"
        }
    }
}

extension AppServices {
    func ticketProviderService(for kind: TicketProviderKind) -> any TicketProviderService {
        switch kind {
        case .github:
            gitHubCLIService
        case .jira:
            jiraCloudService
        }
    }

    var ticketProviderServices: [any TicketProviderService] {
        TicketProviderKind.allCases.map { ticketProviderService(for: $0) }
    }
}
