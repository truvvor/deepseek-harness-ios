import Foundation

/// A single, machine-readable description of a capability that the phone
/// can expose to the agent.  This deliberately includes capabilities which
/// are entitlement-gated or system-mediated: reporting them as unavailable is
/// more useful than making the model guess why an otherwise valid call fails.
struct DeviceCapabilityRecord: Sendable, Equatable {
    let id: String
    let title: String
    let status: String
    let tools: [String]
    let requiresSystemInteraction: Bool
    let entitlement: String?
    let notes: String
}

struct DeviceCapabilityInventory: Sendable, Equatable {
    let records: [DeviceCapabilityRecord]

    func filtered(to capabilityID: String?) -> [DeviceCapabilityRecord] {
        guard let capabilityID else { return records }
        return records.filter { $0.id == capabilityID }
    }
}

protocol DeviceCapabilityInventoryProviding: Sendable {
    func inventory() async -> DeviceCapabilityInventory
}

/// The catalog is intentionally data-only. Adding a new typed native provider
/// or Apple entitlement therefore has one obvious place to document its
/// user-visible boundary. Every listed tool is a signed Swift provider in this
/// build; unavailable capabilities stay explicit instead of using a bridge.
enum DeviceCapabilityCatalog {
    static let records: [DeviceCapabilityRecord] = [
        permission(
            "camera", "Camera", tools: ["camera_ocr"],
            interaction: true, notes: "iOS shows the camera permission prompt on first use; the camera feed is never captured silently in the background."
        ),
        permission(
            "microphone", "Microphone", tools: ["speech_transcribe"],
            interaction: true, notes: "Records only during bounded foreground speech recognition; no background listening."
        ),
        permission(
            "speech", "Speech Recognition", tools: ["speech_transcribe"],
            interaction: true, notes: "Uses Apple Speech for foreground transcription of up to 60 seconds; on-device recognition can be required."
        ),
        permission(
            "location", "Location", tools: ["location_current"],
            interaction: true, notes: "Only requests When In Use location; never used for keep-alive or fake location."
        ),
        permission(
            "motion", "Motion & Fitness", tools: ["motion_activity"],
            interaction: true, notes: "Reads activity estimates for a bounded time window."
        ),
        permission(
            "notifications", "Notifications", tools: ["notification_schedule"],
            interaction: true, notes: "Local notifications are scheduled on the phone; no push server is required."
        ),
        permission(
            "bluetooth", "Bluetooth LE", tools: ["bluetooth_scan"],
            interaction: true, notes: "Currently provides foreground BLE scans of up to 20 seconds; connections and characteristic read/write still need a typed provider per device protocol."
        ),
        permission(
            "contacts", "Contacts", tools: ["contacts_search"],
            interaction: true, notes: "The current tool reads only a limited set of names, phone numbers, and email addresses."
        ),
        permission(
            "photos", "Photo Library", tools: ["photo_library_list"],
            interaction: true, notes: "Can query limited photo/video metadata within the system-granted scope; the chat attachment picker still handles explicit imports."
        ),
        permission(
            "calendar", "Calendar", tools: ["calendar_events"],
            interaction: true, notes: "iOS 17.4+ may distinguish full access from write-only access."
        ),
        permission(
            "reminders", "Reminders", tools: ["reminders_list"],
            interaction: true, notes: "Reminders authorization is managed by EventKit."
        ),
        permission(
            "mediaLibrary", "Media Library", tools: ["media_library_search", "media_playback"],
            interaction: true, notes: "Accesses the on-device music library; this does not grant access to private data from third-party services."
        ),
        permission(
            "healthKit", "HealthKit", tools: ["health_query"],
            interaction: true, entitlement: "com.apple.developer.healthkit",
            notes: "The current signature includes HealthKit; steps, heart rate, HRV, weight, sleep, and workouts are still authorized per data type."
        ),
        permission(
            "homeKit", "HomeKit", status: "notIntegrated", tools: [],
            interaction: true, entitlement: "com.apple.developer.homekit",
            notes: "Requires the HomeKit entitlement and Home access authorization."
        ),
        permission(
            "nfc", "NFC", status: "notIntegrated", tools: [],
            interaction: true, entitlement: "com.apple.developer.nfc.readersession.formats",
            notes: "Each scan opens a visible NFC system session; permanent silent authorization is not possible."
        ),
        staticRecord(
            "clipboard", "Clipboard", status: "session_only", tools: ["clipboard_read", "clipboard_write"],
            interaction: true, notes: "Reading content written by other apps may trigger the iOS paste privacy prompt."
        ),
        staticRecord(
            "biometric_auth", "Device Owner Authentication", status: "available", tools: ["secure_authenticate"],
            interaction: true, notes: "The Face ID/Touch ID/passcode UI is controlled by the system; biometric data is never returned to the model."
        ),
        staticRecord(
            "device_status", "Device Status", status: "available", tools: ["device_status", "device_time"],
            interaction: false, notes: "Battery, storage, thermal state, time, and similar data need no privacy authorization."
        ),
        staticRecord(
            "vision", "Vision On-Device Analysis", status: "available", tools: ["camera_ocr", "vision_analyze"],
            interaction: false, notes: "OCR, barcode, classification, and face-rectangle analysis run on the phone."
        ),
        staticRecord(
            "natural_language", "NaturalLanguage On-Device Text Analysis", status: "available", tools: ["natural_language_analyze"],
            interaction: false, notes: "Tokenization, language identification, sentiment, and entity analysis are not uploaded to the model service."
        ),
        staticRecord(
            "text_to_speech", "System Speech", status: "available", tools: ["speech_synthesize"],
            interaction: false, notes: "Output via on-device AVSpeechSynthesizer; no microphone permission needed."
        ),
        staticRecord(
            "maps", "Maps & Geocoding", status: "available", tools: ["maps_search", "maps_route"],
            interaction: false, notes: "Map queries are still affected by MapKit network and location status."
        ),
        staticRecord(
            "system_deep_links", "System Settings & App Deep Links", status: "available", tools: ["system_open"],
            interaction: true, notes: "Can open phone, messages, mail, web, Settings, and registered app schemes; iOS decides whether the target app exists."
        ),
        staticRecord(
            "file_picker", "File & Photo Pickers", status: "available", tools: ["read", "camera_ocr"],
            interaction: true, notes: "The security scope of file/photo pickers is granted by the user in the system UI."
        ),
        staticRecord(
            "local_network", "Local Network", status: "system_managed", tools: ["web_fetch", "shell_execute"],
            interaction: true, notes: "First access to LAN devices may show the Local Network system prompt; the app cannot approve it silently."
        ),
        staticRecord(
            "app_intents", "Siri, Shortcuts & Spotlight", status: "available", tools: ["AppIntents"],
            interaction: true, notes: "Triggered by the user from Shortcuts or system entry points; no arbitrary background command channel is provided."
        ),
        staticRecord(
            "live_activity", "Live Activities", status: "available", tools: ["continued_processing"],
            interaction: true, notes: "ActivityKit only displays task status; iOS still decides when background execution happens."
        ),
        staticRecord(
            "background_location", "Background Location", status: "constrained", tools: [],
            interaction: true, notes: "Always Location is not enabled, and location is never used as a keep-alive mechanism."
        ),
        staticRecord(
            "background_bluetooth", "Background Bluetooth", status: "constrained", tools: [],
            interaction: true, notes: "Background modes should only be requested for real BLE use cases; this app does not use them for persistent keep-alive."
        ),
        staticRecord(
            "critical_alerts", "Critical Alerts", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.usernotifications.critical-alerts",
            notes: "Requires an entitlement granted through Apple review; regular development signing cannot enable it."
        ),
        staticRecord(
            "nearby_interaction", "Nearby Interaction / UWB", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.nearby-interaction",
            notes: "Requires an accessory protocol and entitlement; without an accessory it cannot serve as a general ranging tool."
        ),
        staticRecord(
            "wifi_info", "Wi-Fi Network Info", status: "entitlement_or_system_managed", tools: [],
            interaction: true, entitlement: "com.apple.developer.networking.wifi-info",
            notes: "SSID/BSSID access is restricted by entitlements, location, and system privacy policies."
        ),
        staticRecord(
            "network_extension", "VPN/Network Extension", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.networking.networkextension",
            notes: "Requires a special Network Extension entitlement and a system configuration flow."
        ),
        staticRecord(
            "family_controls", "Screen Time Controls", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.family-controls",
            notes: "Requires the Family Controls entitlement and user authorization; not enabled because there is no concrete use case yet."
        ),
        staticRecord(
            "sensor_kit", "Research Sensors", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.sensorkit",
            notes: "Only available to approved research studies; not a general permission regular apps can obtain."
        ),
        staticRecord(
            "screen_capture", "Screen Recording", status: "user_initiated_only", tools: [],
            interaction: true, notes: "ReplayKit must be started by the user in the foreground system UI; silent screen recording is not possible."
        ),
        staticRecord(
            "weatherkit", "WeatherKit", status: "service_entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.weatherkit",
            notes: "Requires WeatherKit service configuration; it is not a system privacy permission that can be read arbitrarily."
        ),
        staticRecord(
            "alarmkit", "AlarmKit", status: "os_and_user_authorization_required", tools: [],
            interaction: true, notes: "iOS 26+ alarm authorization and system confirmation flows cannot be silently bypassed by tools."
        ),
        staticRecord(
            "tracking", "Cross-App Tracking", status: "intentionally_disabled", tools: [],
            interaction: true, notes: "Harness contains no advertising or cross-app tracking features, so it never requests ATT."
        ),
    ]

    static var ids: Set<String> { Set(records.map(\.id)) }

    private static func permission(
        _ id: String,
        _ title: String,
        status: String = "unknown",
        tools: [String],
        interaction: Bool,
        entitlement: String? = nil,
        notes: String
    ) -> DeviceCapabilityRecord {
        DeviceCapabilityRecord(
            id: id,
            title: title,
            status: status,
            tools: tools,
            requiresSystemInteraction: interaction,
            entitlement: entitlement,
            notes: notes
        )
    }

    private static func staticRecord(
        _ id: String,
        _ title: String,
        status: String,
        tools: [String],
        interaction: Bool,
        entitlement: String? = nil,
        notes: String
    ) -> DeviceCapabilityRecord {
        DeviceCapabilityRecord(
            id: id,
            title: title,
            status: status,
            tools: tools,
            requiresSystemInteraction: interaction,
            entitlement: entitlement,
            notes: notes
        )
    }
}

enum DeviceCapabilityInventoryBuilder {
    static func build(
        permissionSnapshots: [DevicePermissionSnapshot]
    ) -> DeviceCapabilityInventory {
        let statuses = Dictionary(
            uniqueKeysWithValues: permissionSnapshots.map {
                ($0.capability.rawValue, $0.status.rawValue)
            }
        )
        let records = DeviceCapabilityCatalog.records.map { record in
            guard record.status != "notIntegrated",
                  let status = statuses[record.id] else { return record }
            return DeviceCapabilityRecord(
                id: record.id,
                title: record.title,
                status: status,
                tools: record.tools,
                requiresSystemInteraction: record.requiresSystemInteraction,
                entitlement: record.entitlement,
                notes: record.notes
            )
        }
        return DeviceCapabilityInventory(records: records)
    }
}

#if os(iOS)
struct SystemDeviceCapabilityInventoryProvider: DeviceCapabilityInventoryProviding {
    func inventory() async -> DeviceCapabilityInventory {
        DeviceCapabilityInventoryBuilder.build(
            permissionSnapshots: await DevicePermissionCenter.system.refresh()
        )
    }
}
#else
struct SystemDeviceCapabilityInventoryProvider: DeviceCapabilityInventoryProviding {
    func inventory() async -> DeviceCapabilityInventory {
        DeviceCapabilityInventoryBuilder.build(
            permissionSnapshots: DevicePermissionCapability.allCases.map {
                DevicePermissionSnapshot(capability: $0, status: .unavailable)
            }
        )
    }
}
#endif

struct DeviceCapabilitiesTool: LocalAgentTool {
    private let provider: any DeviceCapabilityInventoryProviding

    let definition = ModelToolDefinition(
        name: "device_capabilities",
        description: "Inspect this iPhone's native tools, current iOS privacy authorization states, and entitlement or system-interaction limits. It only reports state; it never grants a permission or runs a remote command.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "capability": .object([
                    "type": .string("string"),
                    "enum": .array(DeviceCapabilityCatalog.records.map { .string($0.id) }),
                    "description": .string("Optional capability ID to inspect. Omit it to return the complete inventory.")
                ]),
                "include_unavailable": .object([
                    "type": .string("boolean"),
                    "description": .string("Include entitlement-gated and intentionally disabled capabilities. Defaults to true.")
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    init(provider: any DeviceCapabilityInventoryProviding) {
        self.provider = provider
    }

    #if os(iOS)
    init() {
        self.provider = SystemDeviceCapabilityInventoryProvider()
    }
    #endif

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["capability", "include_unavailable"])
        if let capability = arguments["capability"]?.stringValue {
            guard DeviceCapabilityCatalog.ids.contains(capability),
                  capability.utf8.count <= 80 else {
                throw LocalToolError.invalidArguments
            }
        } else if arguments["capability"] != nil {
            throw LocalToolError.invalidArguments
        }
        if let include = arguments["include_unavailable"] {
            guard case .bool = include else { throw LocalToolError.invalidArguments }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        if let capability = arguments["capability"]?.stringValue {
            return "Read phone capability status: \(capability)"
        }
        return "Read phone native capabilities and iOS permission status"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["device-capabilities"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let inventory = await provider.inventory()
        let capabilityID = arguments["capability"]?.stringValue
        let includeUnavailable: Bool
        if case let .bool(value) = arguments["include_unavailable"] {
            includeUnavailable = value
        } else {
            includeUnavailable = true
        }

        let records = inventory.filtered(to: capabilityID).filter { record in
            includeUnavailable || ![
                "unavailable", "notIntegrated", "entitlement_required",
                "service_entitlement_required", "intentionally_disabled"
            ].contains(record.status)
        }
        let values = records.map { record in
            var value: [String: JSONValue] = [
                "id": .string(record.id),
                "title": .string(record.title),
                "status": .string(record.status),
                "tools": .array(record.tools.map(JSONValue.string)),
                "requiresSystemInteraction": .bool(record.requiresSystemInteraction),
                "notes": .string(record.notes)
            ]
            if let entitlement = record.entitlement {
                value["entitlement"] = .string(entitlement)
            }
            return JSONValue.object(value)
        }
        return JSONValue.object([
            "count": .number(Double(values.count)),
            "capabilities": .array(values),
            "executedOn": .string("iPhone")
        ]).displayText
    }
}
