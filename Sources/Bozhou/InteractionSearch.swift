import SwiftUI
import BozhouCore

/// A snapshot is scanned once per committed query or library change, never from a row body.
@MainActor
final class InteractionSearch: ObservableObject {
    struct Row {
        let id: UUID
        let item: Interaction
        let name: HostDisplayName
        var title = ""
    }
    struct Key: Equatable {
        let query: String
        let revision: Int
    }
    @Published private(set) var excerpts: [UUID: String] = [:]
    @Published private(set) var ids: Set<UUID> = []
    func update(_ rows: [Row], query: String) async {
        let result = await TextSearch.background {
            var ids = Set<UUID>(), excerpts: [UUID: String] = [:]
            for row in rows {
                if Task.isCancelled { break }
                let excerpt = TextSearch.excerpt(row.item.output, query: query)
                if query.isEmpty || excerpt != nil ||
                    [row.title, row.name.full, row.item.command, row.item.shell].contains(where: { TextSearch.contains($0, query: query) }) {
                    ids.insert(row.id)
                    excerpts[row.id] = excerpt
                }
            }
            return (ids, excerpts)
        }
        guard !Task.isCancelled else { return }
        excerpts = result.1; ids = result.0
    }
}
