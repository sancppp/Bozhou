import SwiftUI
import BozhouCore
import BozhouExtensions

struct MetadataQueueSummary: View {
    @ObservedObject var coordinator: MetadataCoordinator
    let providerID: String
    var body: some View {
        let statuses = coordinator.statuses.filter { $0.key.hasPrefix(providerID + "/") }.map(\.value)
        let busy = statuses.filter(\.busy).count
        let failed = statuses.filter { if case .failed = $0 { return true }; return false }.count
        Text(L10n.tr("Metadata queries: \(busy) pending · \(failed) failed. Open Host Details for status."))
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct HostMetadataEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var host: Host
    var body: some View {
        ForEach(model.plugins.metadataProviders, id: \.id) { provider in
            HostProviderEditor(host: $host, provider: provider)
        }
    }
}

private struct HostProviderEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var host: Host
    let provider: any HostMetadataProvider
    @State private var choosingFields = false
    private var providerID: String { provider.id }
    private var configuration: PluginSettings { model.plugins.configuration(for: providerID) }
    private var binding: Binding<MetadataBinding> {
        Binding(get: { host.metadataBindings[providerID] ?? MetadataBinding() },
                set: { host.metadataBindings[providerID] = $0 })
    }
    private var saved: Host? {
        model.hosts.first {
            $0.id == host.id &&
            MetadataSubject(host: $0, providerID: providerID) == MetadataSubject(host: host, providerID: providerID)
        }
    }
    private var layout: Binding<MetadataLayout> {
        Binding(get: { host.metadataLayouts[providerID] ?? configuration.layout },
                set: { host.metadataLayouts[providerID] = $0 })
    }
    var body: some View {
        if configuration.enabled {
            Section(provider.title) {
                if !provider.presentation.bindingFields.isEmpty {
                    DisclosureGroup(L10n.tr("Instance Binding")) {
                        ForEach(provider.presentation.bindingFields) { field in
                            let value = Binding(get: { binding.wrappedValue[keyPath: field.keyPath] },
                                                set: { binding.wrappedValue[keyPath: field.keyPath] = $0 })
                            if let choices = field.choices {
                                Picker(field.title, selection: value) {
                                    Text(L10n.tr("Use extension settings")).tag("")
                                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                                }
                            } else { TextField(field.title, text: value, prompt: Text(field.placeholder)) }
                        }
                        Text(provider.presentation.bindingHelp).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let saved {
                    HostMetadataStatus(coordinator: model.metadata, host: saved, providerID: providerID)
                    if let snapshot = saved.metadataSnapshot(for: providerID) {
                        MetadataSnapshotView(snapshot: snapshot, layout: layout.wrappedValue, title: provider.title)
                    }
                } else {
                    Text(L10n.tr("Save the host to query metadata for this binding.")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.tr("Customize fields for this host"), isOn: Binding(
                    get: { host.metadataLayouts[providerID] != nil },
                    set: { host.metadataLayouts[providerID] = $0 ? configuration.layout : nil }))
                if host.metadataLayouts[providerID] != nil {
                    Button(L10n.tr("Visible Fields & Order…")) { choosingFields = true }
                }
            }
            .onAppear { if let saved { model.metadata.request(saved, providerID: providerID, priority: true) } }
            .sheet(isPresented: $choosingFields) {
                MetadataLayoutEditor(fields: saved?.metadataSnapshot(for: providerID)?.fields ?? [], layout: layout)
            }
        }
    }
}

private struct HostMetadataStatus: View {
    @ObservedObject var coordinator: MetadataCoordinator
    let host: Host
    let providerID: String
    var body: some View {
        let status = coordinator.status(hostID: host.id, providerID: providerID)
        HStack {
            if status?.busy == true { ProgressView().controlSize(.small); Text(L10n.tr("Fetching cloud metadata…")).font(.caption) }
            Button(L10n.tr("Refresh Metadata")) { coordinator.request(host, providerID: providerID, force: true, priority: true) }.disabled(status?.busy == true)
        }
        if case .failed(let message) = status {
            Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            if host.metadataSnapshot(for: providerID) != nil {
                Text(L10n.tr("Showing the last successful result.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MetadataSnapshotView: View {
    let snapshot: MetadataSnapshot
    let layout: MetadataLayout
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(L10n.tr("Collected at: \(L10n.date(snapshot.collectedAt))")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(snapshot.notices.enumerated()), id: \.offset) { _, notice in
                Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(layout.arrange(snapshot.fields)) { field in
                    if !field.value.contains("\n"), field.value.count <= 100 {
                        LabeledContent {
                            Text(field.value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        } label: { Text(field.title).foregroundStyle(.secondary) }
                        .font(.caption)
                    } else {
                        DisclosureGroup(field.title) {
                            Text(field.value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption)
                    }
                }
            }
            if layout.arrange(snapshot.fields).isEmpty {
                Text(L10n.tr("All metadata fields are hidden.")).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetadataLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    let fields: [MetadataField]
    @Binding var layout: MetadataLayout
    @State private var search = ""
    var body: some View {
        let ordered = layout.arrange(fields, includeHidden: true)
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Visible Fields & Order")).font(.title3.bold())
            SearchField(title: L10n.tr("Search metadata fields"), text: $search)
            HStack {
                Button(L10n.tr("Show All")) { layout.hidden.subtract(fields.map(\.id)) }
                Button(L10n.tr("Hide All")) { layout.hidden.formUnion(fields.map(\.id)) }
                Button(L10n.tr("Reset to Default")) { layout = MetadataLayout() }
                Spacer()
                Text(L10n.tr("Use arrows to reorder fields.")).font(.caption).foregroundStyle(.secondary)
            }
            if fields.isEmpty {
                Text(L10n.tr("Refresh a host's metadata to discover available fields.")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(ordered.filter { search.isEmpty || TextSearch.contains($0.title, query: search) }) { field in
                        HStack {
                            Toggle(field.title, isOn: Binding(get: { !layout.hidden.contains(field.id) }, set: {
                                if $0 { layout.hidden.remove(field.id) } else { layout.hidden.insert(field.id) }
                            })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                            Button { layout.move(field.id, by: -1, fields: fields) } label: { Image(systemName: "arrow.up") }
                                .disabled(ordered.first?.id == field.id).help(L10n.tr("Move Up"))
                            Button { layout.move(field.id, by: 1, fields: fields) } label: { Image(systemName: "arrow.down") }
                                .disabled(ordered.last?.id == field.id).help(L10n.tr("Move Down"))
                        }.padding(.vertical, 3)
                    }
                }
            }
            HStack { Spacer(); Button(L10n.tr("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 720, height: 570).background(.background)
    }
}
