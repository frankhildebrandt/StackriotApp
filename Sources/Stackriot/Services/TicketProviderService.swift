import Foundation

protocol TicketProviderService {
    var kind: TicketProviderKind { get }

    @MainActor
    func readiness(for repository: ManagedRepository) async -> TicketProviderStatus
    @MainActor
    func searchTickets(query: String, in repository: ManagedRepository) async throws -> [TicketSearchResult]
    @MainActor
    func loadTicket(id: String, in repository: ManagedRepository) async throws -> TicketDetails
}
