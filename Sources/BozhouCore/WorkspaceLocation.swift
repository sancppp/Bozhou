import Foundation

public enum WorkspaceLocation {
    public static func copy(store: Store, from source: AppPaths, to destination: URL) throws -> AppPaths {
        let fm = FileManager.default
        let origin = source.root.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard target != origin, !target.path.hasPrefix(origin.path + "/"), !origin.path.hasPrefix(target.path + "/") else {
            throw BozhouError.storage("请选择与当前数据目录互不包含的新目录")
        }
        if fm.fileExists(atPath: target.path) {
            guard try fm.contentsOfDirectory(atPath: target.path).isEmpty else {
                throw BozhouError.storage("目标目录必须为空，以免覆盖现有数据")
            }
        }
        let paths = try AppPaths(root: target)
        try store.backup(to: paths.database)
        try Data(contentsOf: source.knownHosts).write(to: paths.knownHosts, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.knownHosts.path)
        for url in try fm.contentsOfDirectory(at: source.logs, includingPropertiesForKeys: nil) {
            try fm.copyItem(at: url, to: paths.logs.appendingPathComponent(url.lastPathComponent))
        }
        // Open and decode the copied records before the caller changes its startup pointer.
        let copied = try Store(url: paths.database)
        _ = try copied.list(Host.self); _ = try copied.list(HostFolder.self)
        _ = try copied.list(Identity.self); _ = try copied.list(Interaction.self)
        _ = try copied.list(Pin.self); _ = try copied.list(Snippet.self); _ = try copied.loadSettings()
        return paths
    }
}
