import AppKit
import SwiftUI
import BozhouCore
import BozhouExtensions
import BozhouNightHawk

@main
struct NativeMetadataTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = try AppModel()
        let provider = NightHawkProvider.identifier
        precondition(model.settings.plugins.isEmpty)
        model.startPlugins()
        precondition(model.metadata.statuses.isEmpty)
        var host = Host(name: "Cloud fixture", address: "192.0.2.8")
        host.systemProfile = SystemProfile(operatingSystem: "PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"\nID=debian",
                                           kernel: "6.1 arm64", cpu: "Model name: Ampere Altra\nCPU(s): 8",
                                           memory: "MemAvailable: 16777216 kB", hostname: "fixture-123456")
        let fields = [
            MetadataField(id: "ECS/id", title: "ECS › id", value: "i-fixture00001"),
            .init(id: "ECS/detail/account", title: "ECS › 账户", value: "100"),
            .init(id: "ENI/addresses", title: "ENI › 私网 IPv4", value: "eni-fixture00001: 192.0.2.8"),
            .init(id: "VPC/description", title: "VPC › 描述", value: "Fictional isolated test VPC"),
            .init(id: "ENI/tags/purpose", title: "ENI › 标签 / purpose", value: "fixture")
        ]
        let snapshot = MetadataSnapshot(providerID: provider, subjectKey: MetadataSubject(host: host, providerID: provider).key,
                                        resourceID: "i-fixture00001", region: "cn-test", accountID: "100",
                                        environment: "cn", fields: fields, notices: [])
        try model.store.save(host)
        try model.store.saveMetadata(snapshot, hostID: host.id); try model.reload()
        // The host editor was opened before the metadata reply.
        host.notes = "draft retained"; var layout = MetadataLayout()
        layout.hidden.insert("VPC/description"); layout.move("ENI/tags/purpose", by: -1, fields: fields)
        host.metadataLayouts[provider] = layout
        try model.saveHost(host)
        host = model.hosts.first!
        precondition(host.metadataSnapshot(for: provider) == snapshot)
        precondition(host.notes == "draft retained" && host.metadataLayouts[provider] == layout)
        var config = PluginSettings(); config.enabled = true
        model.settings.plugins[provider] = config
        model.saveSettings()
        precondition(model.metadata.statuses.isEmpty, "Fresh cached metadata must avoid launching the CLI")
        let loaded = try AppModel()
        precondition(loaded.settings.plugins[provider]?.enabled == true)
        precondition(loaded.hosts.first?.metadataLayouts[provider] == layout)
        for query in ["fictional isolated", "draft retained", "arm64", "192.0.2.8", "fixture-123456"] {
            model.search = query
            await model.hostSearchTask?.value
            precondition(model.filteredHosts.map(\.id) == [host.id], "Details search missed \(query)")
        }
        model.search = "query-with-no-match"
        model.search = "fictional isolated"
        await model.hostSearchTask?.value
        precondition(model.filteredHosts.map(\.id) == [host.id], "An older search replaced the current result")
        let output = model.paths.root.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in AppLanguage.allCases {
            model.settings.language = language; model.saveSettings()
            // Plugin descriptors are created after language selection at application startup.
            let localized = try AppModel()
            let name = language.rawValue
            precondition(localized.plugins.descriptors.first?.title == L10n.tr("Volcengine ECS metadata · NightHawk"))
            try await render(Form { PluginSettingsView() }.formStyle(.grouped).environmentObject(localized),
                       size: NSSize(width: 850, height: 530), output: output.appendingPathComponent(name + "-settings.png"))
            try await render(Form { HostMetadataEditor(host: .constant(host)) }.formStyle(.grouped).environmentObject(localized),
                       size: NSSize(width: 540, height: 600), output: output.appendingPathComponent(name + "-host.png"))
            try await render(HostQuickLook(host: host, hosts: localized.hosts, settings: localized.settings, providers: localized.plugins.metadataProviders),
                       size: NSSize(width: 520, height: 640), output: output.appendingPathComponent(name + "-preview.png"))
            try await render(MetadataLayoutEditor(fields: fields, layout: .constant(layout)),
                       size: NSSize(width: 764, height: 614), output: output.appendingPathComponent(name + "-fields.png"))
        }
        model.settings.plugins[provider]?.enabled = false; model.saveSettings()
        await model.hostSearchTask?.value
        precondition(model.filteredHosts.isEmpty, "Disabled plugin data must leave search results")
        model.search = ""
        precondition(model.filteredHosts.count == 1, "Clearing search must apply immediately")
        precondition(model.metadata.statuses.isEmpty)
        print("PASS native metadata: disabled default, cached queries, editor draft merge, persisted layouts, bilingual settings/details/preview/field ordering")
        print("RENDERS \(output.path)")
    }
    @MainActor static func render<V: View>(_ view: V, size: NSSize, output: URL) async throws {
        let content = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        content.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(120))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        precondition(content.fittingSize.width <= size.width + 1, "Metadata view exceeds available width: \(output.lastPathComponent)")
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        window.orderOut(nil)
    }
}
