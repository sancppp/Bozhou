import Foundation

public extension Store {
    func identityGroups() throws -> [String] {
        Array(Set(try list(IdentityFolder.self).flatMap { HostTree.ancestors($0.path) }
            + list(Identity.self).flatMap { HostTree.ancestors($0.group) })).sorted()
    }

    private func ensureIdentityFolders(_ path: String) throws {
        let existing = Set(try list(IdentityFolder.self).map(\.path))
        for ancestor in HostTree.ancestors(path) where !existing.contains(ancestor) {
            try save(IdentityFolder(path: ancestor))
        }
    }

    func saveIdentity(_ identity: Identity) throws {
        var identity = identity
        identity.group = try HostTree.normalize(identity.group)
        guard !identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BozhouError.invalid(L10n.tr("Enter a key name"))
        }
        try transaction {
            try ensureIdentityFolders(identity.group)
            try save(identity)
        }
    }

    func createIdentityFolder(_ path: String) throws {
        let path = try HostTree.normalize(path)
        guard !path.isEmpty else { throw BozhouError.invalid(L10n.tr("Enter a folder name")) }
        try transaction { try ensureIdentityFolders(path) }
    }

    func renameIdentityFolder(_ path: String, to destination: String) throws {
        let target = try HostTree.normalize(destination)
        try transaction {
            let groups = try identityGroups()
            guard groups.contains(path), !target.isEmpty, target != path,
                  !HostTree.contains(target, in: path), !groups.contains(target) else {
                throw BozhouError.invalid(L10n.tr("Destination folder already exists or the path is invalid"))
            }
            for var folder in try list(IdentityFolder.self) where HostTree.contains(folder.path, in: path) {
                folder.path = target + folder.path.dropFirst(path.count)
                try save(folder)
            }
            for var key in try list(Identity.self) where HostTree.contains(key.group, in: path) {
                key.group = target + key.group.dropFirst(path.count)
                try save(key)
            }
            try ensureIdentityFolders(target)
            var settings = try loadSettings()
            settings.expandedIdentityGroups = Set(settings.expandedIdentityGroups.map {
                HostTree.contains($0, in: path) ? target + $0.dropFirst(path.count) : $0
            })
            try saveSettings(settings)
        }
    }

    func deleteIdentityFolder(_ path: String) throws {
        try transaction {
            guard !path.isEmpty,
                  try !list(Identity.self).contains(where: { HostTree.contains($0.group, in: path) }),
                  try !identityGroups().contains(where: { $0 != path && HostTree.contains($0, in: path) }) else {
                throw BozhouError.invalid(L10n.tr("Only empty folders can be deleted. Move their keys or subfolders first."))
            }
            for folder in try list(IdentityFolder.self) where folder.path == path {
                try delete(IdentityFolder.self, id: folder.id)
            }
            var settings = try loadSettings()
            settings.expandedIdentityGroups = settings.expandedIdentityGroups.filter { !HostTree.contains($0, in: path) }
            try saveSettings(settings)
        }
    }
}
