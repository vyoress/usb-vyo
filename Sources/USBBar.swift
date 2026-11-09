import AppKit
import SwiftUI
import IOKit
import DiskArbitration
import ServiceManagement

struct LinkSpeed {
    let code: Int?
    var fast: Bool { (code ?? -1) >= 3 }
    var label: String {
        switch code {
        case 0: return "USB 1 · 1,5 Mbit/s"
        case 1: return "USB 1 · 12 Mbit/s"
        case 2: return "USB 2.0 · 480 Mbit/s"
        case 3: return "USB 3 · 5 Gbit/s"
        case 4: return "USB 3 · 10 Gbit/s"
        case 5: return "USB 3 · 20 Gbit/s"
        default: return "Velocità non disponibile"
        }
    }
    var short: String {
        switch code {
        case 0, 1: return "USB 1"
        case 2: return "USB 2.0"
        case 3: return "USB 5G"
        case 4: return "USB 10G"
        case 5: return "USB 20G"
        default: return "USB ?"
        }
    }
}

struct USBDrive: Identifiable {
    let id: UInt64
    let bsd: String
    let name: String
    let size: Int64
    let speed: LinkSpeed
    let disk: DADisk
}

enum USBScanner {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func scan(session: DASession) -> [USBDrive] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [USBDrive] = []
        while true {
            let media = IOIteratorNext(iterator)
            if media == 0 { break }
            defer { IOObjectRelease(media) }
            guard property(media, "Whole") as? Bool == true,
                  let bsd = property(media, "BSD Name") as? String,
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false,
                  description[kDADiskDescriptionDeviceProtocolKey as String] as? String == "USB" else { continue }
            var entry = media
            IOObjectRetain(entry)
            var speed: Int?
            var isLogicalMedia = false
            while entry != 0 {
                if entry != media && IOObjectConformsTo(entry, "IOMedia") != 0 { isLogicalMedia = true }
                if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0 {
                    speed = (property(entry, "Device Speed") as? NSNumber)?.intValue
                    IOObjectRelease(entry)
                    break
                }
                var parent: io_registry_entry_t = 0
                let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
                IOObjectRelease(entry)
                if result != KERN_SUCCESS { break }
                entry = parent
            }
            // APFS containers also report Whole=true, but belong to a physical disk.
            guard !isLogicalMedia else { continue }
            var identifier: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(media, &identifier)
            let vendor = description[kDADiskDescriptionDeviceVendorKey as String] as? String ?? ""
            let model = description[kDADiskDescriptionDeviceModelKey as String] as? String ?? bsd
            let name = "\(vendor) \(model)".trimmingCharacters(in: .whitespaces)
            drives.append(USBDrive(id: identifier, bsd: bsd, name: name,
                size: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
                speed: LinkSpeed(code: speed), disk: disk))
        }
        return drives.sorted { $0.bsd < $1.bsd }
    }
}

final class Monitor: ObservableObject {
    @Published var drives: [USBDrive] = []
    @Published var busy: UInt64?
    @Published var message: String?
    @Published var isError = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    let session = DASessionCreate(kCFAllocatorDefault)!
    var timer: Timer?
    var changed: (() -> Void)?

    init() {
        DASessionSetDispatchQueue(session, .main)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let latest = USBScanner.scan(session: session)
        if latest.map(\.id) != drives.map(\.id) || latest.map(\.speed.code) != drives.map(\.speed.code) {
            if busy == nil && latest.contains(where: { incoming in !drives.contains(where: { $0.id == incoming.id }) }) {
                message = nil
                isError = false
            }
            drives = latest
            changed?()
        }
    }

    func eject(_ drive: USBDrive) {
        guard busy == nil else { return }
        guard USBScanner.scan(session: session).contains(where: { $0.id == drive.id }) else {
            message = "La chiavetta non è più collegata."
            isError = true
            refresh()
            return
        }
        busy = drive.id
        message = "Espulsione in corso. Attendi prima di scollegare."
        isError = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", "/dev/" + drive.bsd]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            finishEject(drive, error: error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let details = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = process.terminationStatus == 0 ? nil : (details ?? "Il disco è occupato.")
            DispatchQueue.main.async { self?.finishEject(drive, error: error) }
        }
    }

    private func finishEject(_ drive: USBDrive, error: String?) {
        busy = nil
        isError = error != nil
        if let error {
            message = "Espulsione non riuscita. Chiudi i file e le app che usano la chiavetta e riprova. \(error)"
        } else {
            message = "\(drive.name): espulsa. Ora puoi scollegarla."
        }
        refresh()
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                message = "Autorizza USB Vyo in Impostazioni di Sistema → Generali → Elementi login."
            }
        } catch {
            message = "Avvio automatico non aggiornato: \(error.localizedDescription)"
            isError = true
        }
    }
}

struct DriveCard: View {
    let drive: USBDrive
    @ObservedObject var monitor: Monitor
    var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(drive.name).font(.headline)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: drive.size, countStyle: .decimal)).font(.caption).foregroundStyle(.secondary)
                    }
                    Label(drive.speed.label, systemImage: drive.speed.fast ? "bolt.fill" : "exclamationmark.circle.fill")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(drive.speed.fast ? .teal : .orange)
                    Text(drive.speed.fast ? "Collegamento SuperSpeed attivo" : "Se attendevi USB 3, controlla porta, cavo o adattatore.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { monitor.eject(drive) } label: {
                        HStack {
                            if monitor.busy == drive.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: "eject.fill") }
                            Text(monitor.busy == drive.id ? "Espulsione…" : "Espelli in sicurezza")
                            Spacer()
                        }.padding(.vertical, 4)
                    }.disabled(monitor.busy != nil)
                }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Panel: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "externaldrive.fill.badge.checkmark").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("USB Vyo").font(.headline)
                    Text("Il collegamento, a colpo d’occhio").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if monitor.drives.isEmpty {
                Label("Nessuna unità USB rilevata", systemImage: "cable.connector").foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
            ForEach(monitor.drives) { drive in
                DriveCard(drive: drive, monitor: monitor)
            }
            if let message = monitor.message {
                Label(message, systemImage: monitor.isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption).foregroundStyle(monitor.isError ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("La velocità indica il collegamento USB, non la velocità di copia né il massimo supportato dalla chiavetta. Espelli sempre prima di staccarla: una scrittura interrotta può danneggiare i dati.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Apri all’accesso", isOn: Binding(get: { monitor.loginEnabled }, set: { _ in monitor.toggleLogin() }))
                .toggleStyle(.checkbox).font(.caption)
            HStack {
                Button("Ricontrolla USB") { monitor.refresh() }
                    .help("Rileva di nuovo le unità e la velocità del collegamento USB. Il controllo avviene anche automaticamente ogni due secondi.")
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }.disabled(monitor.busy != nil)
            }.font(.caption)
        }.padding(20).frame(width: 370)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(monitor: monitor))
        monitor.changed = { [weak self] in self?.updateTitle() }
        updateTitle()
        if !UserDefaults.standard.bool(forKey: "hasOpened") {
            UserDefaults.standard.set(true, forKey: "hasOpened")
            DispatchQueue.main.async { self.toggle() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }
        return false
    }
    func updateTitle() {
        let slowest = monitor.drives.min { ($0.speed.code ?? -1) < ($1.speed.code ?? -1) }
        item.button?.title = slowest.map { $0.speed.short + (monitor.drives.count > 1 ? " · \(monitor.drives.count)" : "") } ?? "USB —"
        item.button?.image = NSImage(systemSymbolName: slowest?.speed.fast == false ? "exclamationmark.circle" : "externaldrive", accessibilityDescription: "Stato USB")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = monitor.drives.isEmpty ? "Nessuna unità USB" : monitor.drives.map { "\($0.name): \($0.speed.label)" }.joined(separator: "\n")
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            monitor.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

if CommandLine.arguments.contains("--diagnose") {
    let session = DASessionCreate(kCFAllocatorDefault)!
    for drive in USBScanner.scan(session: session) {
        print("\(drive.bsd) | \(drive.name) | \(drive.speed.label) | registry \(drive.id)")
    }
} else if CommandLine.arguments.contains("--self-test") {
    precondition(LinkSpeed(code: 2).short == "USB 2.0")
    precondition(!LinkSpeed(code: 2).fast)
    precondition(LinkSpeed(code: 3).label == "USB 3 · 5 Gbit/s")
    precondition(LinkSpeed(code: 3).fast)
    precondition(LinkSpeed(code: nil).short == "USB ?")
    precondition(!LinkSpeed(code: nil).fast)
    print("Controlli velocità superati.")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
