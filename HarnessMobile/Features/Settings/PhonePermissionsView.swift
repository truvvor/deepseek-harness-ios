import SwiftUI
import UIKit

struct PhonePermissionsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var snapshots = DevicePermissionCapability.allCases.map {
        DevicePermissionSnapshot(capability: $0, status: .notDetermined)
    }
    @State private var isRefreshing = false

    private let center: DevicePermissionCenter

    init(center: DevicePermissionCenter = .system) {
        self.center = center
    }

    var body: some View {
        Form {
            permissionSection("Privacy Access", capabilities: [
                .camera, .microphone, .speech, .location, .motion,
                .contacts, .photos, .calendar, .reminders, .mediaLibrary,
            ])
            permissionSection("System Connections", capabilities: [
                .notifications, .bluetooth, .localNetwork,
            ])
            permissionSection("Additional Capabilities", capabilities: [
                .healthKit, .homeKit, .nfc,
            ])

            Section {
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                }
            } footer: {
                Text("This page only reads current status. iOS requests a permission only when you use the related feature or approve a related tool call.")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Phone Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh Permission Status")
                .help("Refresh Permission Status")
            }
        }
    }

    @ViewBuilder
    private func permissionSection(
        _ title: String,
        capabilities: [DevicePermissionCapability]
    ) -> some View {
        Section {
            ForEach(capabilities) { capability in
                DevicePermissionRow(
                    capability: capability,
                    status: status(for: capability)
                )
            }
        } header: {
            Label(title, systemImage: sectionIcon(for: title))
        }
    }

    private func sectionIcon(for title: String) -> String {
        switch title {
        case "Privacy Access": return "hand.raised"
        case "System Connections": return "point.3.connected.trianglepath.dotted"
        default: return "sparkles"
        }
    }

    private func status(for capability: DevicePermissionCapability) -> DevicePermissionStatus {
        snapshots.first(where: { $0.capability == capability })?.status ?? .unavailable
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshots = await center.refresh()
        isRefreshing = false
    }
}

private struct DevicePermissionRow: View {
    let capability: DevicePermissionCapability
    let status: DevicePermissionStatus
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(capability.purpose(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 44)
                .padding(.top, HarnessTheme.Spacing.xSmall)
        } label: {
            HStack(spacing: 12) {
                HarnessIconTile(systemImage: capability.systemImage, tint: capability.tint)
                Text(capability.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HarnessStatusPill(
                    title: status.title,
                    systemImage: status.systemImage,
                    tint: status.tint
                )
            }
        }
        .padding(.vertical, HarnessTheme.Spacing.xSmall)
        .accessibilityIdentifier("phone-permission-\(capability.rawValue)")
    }
}

private extension DevicePermissionCapability {
    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .location: "Location"
        case .motion: "Motion & Fitness"
        case .notifications: "Notifications"
        case .bluetooth: "Bluetooth"
        case .localNetwork: "Local Network"
        case .contacts: "Contacts"
        case .photos: "Photos"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .mediaLibrary: "Media Library"
        case .healthKit: "HealthKit"
        case .homeKit: "HomeKit"
        case .nfc: "NFC"
        }
    }

    func purpose(for status: DevicePermissionStatus) -> String {
        switch self {
        case .camera: "Used for taking photos and on-device OCR."
        case .microphone: "Used for voice input on the phone."
        case .speech: "Used to convert speech to text."
        case .location: "The location tool fetches your current location once."
        case .motion: "Reads activity estimates over a limited time range."
        case .notifications: "Used for local reminders and task completion notifications."
        case .bluetooth: "Used for approved BLE device operations."
        case .localNetwork: "iOS has no read-only status query; only actual local network operations trigger the system prompt."
        case .contacts: "Contact search returns only limited names, phone numbers, and emails."
        case .photos: "Distinguishes read/write, limited access, and add-only photo permissions."
        case .calendar: "Supports write-only or full access, as requested by each tool."
        case .reminders: "Supports write-only or full access, as requested by each tool."
        case .mediaLibrary: "Used to access the on-device music library."
        case .healthKit:
            switch status {
            case .notIntegrated:
                "The current signature does not include the HealthKit capability. Use a device build with that entitlement enabled."
            case .unavailable:
                "This device does not support HealthKit."
            default:
                "Typed Swift HealthKit queries are integrated; authorization for each data type is still managed by the Health app."
            }
        case .homeKit: "The HomeKit capability is not configured."
        case .nfc: "No persistent authorization; each scan uses a system session."
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .speech: "waveform"
        case .location: "location"
        case .motion: "figure.walk.motion"
        case .notifications: "bell"
        case .bluetooth: "bluetooth"
        case .localNetwork: "network"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .mediaLibrary: "music.note.list"
        case .healthKit: "heart"
        case .homeKit: "house"
        case .nfc: "wave.3.right"
        }
    }

    var tint: Color {
        switch self {
        case .camera, .photos: .blue
        case .microphone, .speech, .mediaLibrary: .purple
        case .location, .motion: .green
        case .notifications, .calendar, .reminders: .orange
        case .bluetooth: .cyan
        case .localNetwork: .gray
        case .contacts: .indigo
        case .healthKit: .red
        case .homeKit: .teal
        case .nfc: .secondary
        }
    }
}

private extension DevicePermissionStatus {
    var title: String {
        switch self {
        case .notDetermined: "Not Requested"
        case .authorized: "Allowed"
        case .limited: "Limited"
        case .writeOnly: "Add/Write Only"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .unavailable: "Unavailable"
        case .notIntegrated: "Not Integrated"
        case .systemManaged: "System Managed"
        case .sessionOnly: "Per Session"
        }
    }

    var systemImage: String {
        switch self {
        case .authorized: "checkmark.circle.fill"
        case .limited, .sessionOnly: "circle.lefthalf.filled"
        case .writeOnly: "arrow.up.circle"
        case .notDetermined: "questionmark.circle"
        case .denied: "xmark.circle.fill"
        case .restricted: "lock.circle"
        case .unavailable: "minus.circle"
        case .notIntegrated: "wrench.and.screwdriver"
        case .systemManaged: "gearshape.circle"
        }
    }

    var tint: Color {
        switch self {
        case .authorized: .green
        case .limited, .sessionOnly, .writeOnly, .systemManaged: .orange
        case .denied, .restricted: .red
        case .notDetermined, .unavailable, .notIntegrated: .secondary
        }
    }
}
