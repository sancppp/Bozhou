import SwiftUI
import BozhouCore
import BozhouExtensions

struct PluginSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section(L10n.tr("Extensions")) {
            ForEach(model.plugins.descriptors) { descriptor in
                PluginConfigurationView(descriptor: descriptor)
            }
        }
    }
}

private struct PluginConfigurationView: View {
    @EnvironmentObject var model: AppModel
    let descriptor: PluginDescriptor
    @State private var choosingFields = false
    private var configuration: Binding<PluginSettings> {
        Binding(get: {
            (model.settings.plugins[descriptor.id] ?? PluginSettings()).applyingDefaults(descriptor.defaults)
        }, set: { model.settings.plugins[descriptor.id] = $0 })
    }
    private var catalog: [MetadataField] {
        var fields: [String: MetadataField] = [:]
        for host in model.hosts {
            for field in host.metadataSnapshot(for: descriptor.id)?.fields ?? [] where fields[field.id] == nil {
                fields[field.id] = field
            }
        }
        return Array(fields.values)
    }
    var body: some View {
        Toggle(descriptor.title, isOn: configuration.enabled)
        if !descriptor.summary.isEmpty { Text(descriptor.summary).font(.caption).foregroundStyle(.secondary) }
        if let failure = model.plugins.failures[descriptor.id] {
            Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if configuration.wrappedValue.enabled {
            ForEach(descriptor.settings) { setting in
                switch setting.kind {
                case .text, .executable:
                    PluginTextSetting(setting: setting, configuration: configuration)
                case .choices(let choices):
                    HStack {
                        Text(setting.title)
                        ForEach(choices, id: \.self) { choice in
                            Toggle(choice, isOn: Binding(get: {
                                configuration.wrappedValue.selections[setting.id, default: []].contains(choice)
                            }, set: { enabled in
                                var value = configuration.wrappedValue
                                value.selections[setting.id, default: []].removeAll { $0 == choice }
                                if enabled { value.selections[setting.id, default: []].append(choice) }
                                configuration.wrappedValue = value
                            })).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            if !descriptor.help.isEmpty { Text(descriptor.help).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if model.plugins.metadataProvider(for: descriptor.id) != nil {
                HStack {
                    Button(L10n.tr("Refresh Metadata")) { model.refreshMetadata(providerID: descriptor.id, force: true) }
                        .disabled(!model.plugins.isActive(descriptor.id))
                    Button(L10n.tr("Visible Fields & Order…")) { choosingFields = true }
                }
                Text(L10n.tr("Field preferences apply to this workspace. Each host can override them in Host Details. New properties are visible by default."))
                    .font(.caption).foregroundStyle(.secondary)
                MetadataQueueSummary(coordinator: model.metadata, providerID: descriptor.id)
            }
        }
        Color.clear.frame(height: 0).sheet(isPresented: $choosingFields) {
            MetadataLayoutEditor(fields: catalog, layout: configuration.layout)
        }
    }
}

private struct PluginTextSetting: View {
    let setting: PluginSetting
    @Binding var configuration: PluginSettings
    @State private var draft = ""
    var body: some View {
        HStack {
            TextField(setting.title, text: $draft, prompt: Text(setting.placeholder))
                .onSubmit { configuration.options[setting.id] = draft }
            if case .executable = setting.kind {
                Button(L10n.tr("Choose…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        draft = url.path; configuration.options[setting.id] = draft
                    }
                }
            }
            Button(L10n.tr("Apply")) { configuration.options[setting.id] = draft }
        }
        .onAppear { draft = configuration.options[setting.id] ?? "" }
        .onChange(of: configuration.options[setting.id]) { _, value in draft = value ?? "" }
    }
}
