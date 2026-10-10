import Foundation
import Observation

/// The settings sheet owns its draft; only a successful save changes review defaults.
@MainActor
@Observable
final class BuildConfigurationModel: Identifiable {
    let session: Session
    var id: UUID { session.id }
    private(set) var schemes: [String] = []
    private(set) var destinations: [BuildDestination] = []
    private(set) var scheme: String
    var destinationID: String
    private(set) var error: String?
    @ObservationIgnored private let coordinator: ReviewCoordinator

    init(session: Session, coordinator: ReviewCoordinator) {
        self.session = session
        self.coordinator = coordinator
        scheme = session.repository.buildSettings?.scheme ?? ""
        destinationID = session.repository.buildSettings?.destination.id ?? ""
    }

    var settings: BuildSettings? {
        guard schemes.contains(scheme),
              let destination = destinations.first(where: { $0.id == destinationID }) else { return nil }
        return BuildSettings(scheme: scheme, destination: destination)
    }

    func selectScheme(_ name: String) {
        guard name != scheme else { return }
        scheme = name
        destinations = []
        destinationID = ""
        error = nil
    }

    func load() async {
        schemes = []
        destinations = []
        error = nil
        do {
            schemes = try await coordinator.schemes(for: session)
            if !schemes.contains(scheme) { selectScheme(schemes.first ?? "") }
            if !scheme.isEmpty { try await fetchDestinations() }
        } catch { self.error = error.localizedDescription }
    }

    func loadDestinations() async {
        destinations = []
        destinationID = ""
        error = nil
        do { try await fetchDestinations() }
        catch { self.error = error.localizedDescription }
    }

    func save() -> Bool {
        guard let settings else {
            error = "利用可能なSchemeと実行先を選んでください。"
            return false
        }
        do {
            try coordinator.saveBuildSettings(settings, for: session)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func fetchDestinations() async throws {
        destinations = try await coordinator.destinations(for: session, scheme: scheme)
        if !destinations.contains(where: { $0.id == destinationID }) {
            destinationID = destinations.first?.id ?? ""
        }
    }
}
