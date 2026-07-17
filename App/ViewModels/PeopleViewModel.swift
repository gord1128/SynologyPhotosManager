import Foundation
import Observation
import FotoKit

/// Drives the People screen: the list of recognized face clusters. One instance
/// per connected service (recreated on connection/space change). Read-only —
/// Synology does the face recognition server-side.
@Observable
@MainActor
final class PeopleViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    private(set) var people: [FotoPerson] = []
    private(set) var isLoading = false
    var errorMessage: String?

    /// Whether to show unnamed clusters (Synology hides them behind a toggle).
    var showUnnamed = true

    /// Named people first, then (optionally) unnamed — each already ordered by
    /// photo count as DSM returns them.
    var visiblePeople: [FotoPerson] {
        let named = people.filter(\.isNamed)
        guard showUnnamed else { return named }
        return named + people.filter { !$0.isNamed }
    }

    var namedCount: Int { people.lazy.filter(\.isNamed).count }
    var unnamedCount: Int { people.count - namedCount }

    private var loadedOnce = false

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            people = try await service.persons()
            errorMessage = nil
        } catch {
            people = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Names or renames a person (empty string clears the name). Reloads so the
    /// named/unnamed ordering + toggle stay correct.
    func rename(_ person: FotoPerson, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != person.name else { return }
        do {
            try await service.renamePerson(id: person.id, name: trimmed)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// An already-existing (different) person with this exact name, if any —
    /// renaming to it should merge rather than create a duplicate.
    func existingPerson(forName name: String, excluding personId: Int) -> FotoPerson? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return people.first { $0.id != personId && $0.name == trimmed }
    }

    /// Merges `source` into `target` (keeping target's name + id), then reloads.
    /// ⚠️ Irreversible — combines the two face clusters permanently.
    func merge(_ source: FotoPerson, into target: FotoPerson) async {
        do {
            try await service.mergePersons(targetId: target.id, mergedIds: [source.id], name: target.name)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Sets a person's cover to one of their photos, then reloads so the grid
    /// card shows the new face crop (the cover's cache_key changes → fresh load).
    func setCover(personId: Int, photoId: Int) async {
        do {
            try await service.setPersonCover(personId: personId, photoId: photoId)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
