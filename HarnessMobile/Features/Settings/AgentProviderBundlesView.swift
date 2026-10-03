import SwiftUI

struct AgentProviderBundlesView: View {
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(model.providerBundles) { bundle in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: binding(for: bundle)) {
                            Label {
                                Text(bundle.displayName)
                            } icon: {
                                HarnessIconTile(
                                    systemImage: bundle.id == .codex ? "terminal" : "text.bubble",
                                    tint: bundle.enabled ? .accentColor : .secondary,
                                    size: 28
                                )
                            }
                        }
                        installStatus(for: bundle)
                        installActions(for: bundle)
                        Text("Pinned source: \(bundle.installPayload.packageName)@\(bundle.installPayload.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                DisclosureGroup("Installation & Security") {
                    Text("The URL, SHA-256, npm package identity, CLI name, and commands all come from a built-in, non-editable manifest. Downloads are verified and then replaced atomically; a failure or cancellation keeps the previous version. The installer never reads model provider API Keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Built-in Agent Bundles")
            } footer: {
                Text("Installation runs inside iSH on this phone; downloads are verified and then replaced atomically.")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Agent Orchestration")
        .alert("Bundle Setup Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await model.refreshProviderBundleInstallStatuses()
        }
    }

    @ViewBuilder
    private func installStatus(for bundle: AgentProviderBundle) -> some View {
        let status = model.providerBundleInstallStatus(bundle.id)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if status.phase.isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                HarnessIconTile(
                    systemImage: status.phase == .installed ? "checkmark.seal.fill" : "shippingbox",
                    tint: status.phase == .installed ? .green : .secondary,
                    size: 28
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.message)
                    .font(.caption)
                if let version = status.installedVersion {
                    Text("Verified version \(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func installActions(for bundle: AgentProviderBundle) -> some View {
        let status = model.providerBundleInstallStatus(bundle.id)
        HStack(spacing: 12) {
            if status.phase.isActive {
                Button("Cancel") {
                    model.cancelProviderBundleInstall(bundle.id)
                }
                .buttonStyle(.bordered)
            } else {
                Button(status.phase == .installed ? "Reinstall" : "Install on Phone") {
                    model.startProviderBundleInstall(
                        bundle.id,
                        reinstall: status.phase == .installed
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func binding(for bundle: AgentProviderBundle) -> Binding<Bool> {
        Binding(
            get: { model.providerBundle(bundle.id)?.enabled == true },
            set: { enabled in
                do {
                    try model.setProviderBundleEnabled(bundle.id, enabled: enabled)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}
