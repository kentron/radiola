//
//  AirPlayDevice.swift
//  Radiola
//
//  Created by kentron on 20.11.2026.
//
//  AirPlay 1 (RAOP) receivers discovered over Bonjour.
//

import Cocoa
import Foundation
import Network

extension Notification.Name {
    static let AirPlayDevicesChanged = Notification.Name("AirPlayDevicesChanged")
}

// MARK: - AirPlayDevice

struct AirPlayDevice: Equatable {
    static let uidPrefix = "airplay:"

    /// Bonjour service name of the `_raop._tcp` service, e.g. "68A86D5BAA7A@Happiness"
    let serviceName: String

    var uid: String { AirPlayDevice.uidPrefix + serviceName }

    /// Human readable name, the part after "@"
    var name: String {
        guard let at = serviceName.firstIndex(of: "@") else { return serviceName }
        return String(serviceName[serviceName.index(after: at)...])
    }

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    /// Returns nil when the UID does not describe an AirPlay device.
    init?(uid: String?) {
        guard let uid, uid.hasPrefix(AirPlayDevice.uidPrefix) else { return nil }
        let name = String(uid.dropFirst(AirPlayDevice.uidPrefix.count))
        guard !name.isEmpty else { return nil }
        serviceName = name
    }
}

// MARK: - AirPlayBrowser

/// Discovers AirPlay receivers that accept unencrypted RAOP audio.
final class AirPlayBrowser {
    static let shared = AirPlayBrowser()

    private(set) var devices: [AirPlayDevice] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: nil), using: params)
        let ownName = Host.current().localizedName

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> AirPlayDevice? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                let device = AirPlayDevice(serviceName: name)

                // Skip this Mac's own AirPlay receiver
                if device.name == ownName { return nil }

                // Only receivers that accept unencrypted audio (et=0) are supported
                if case let .bonjour(txt) = result.metadata, let et = txt.dictionary["et"] {
                    if !et.split(separator: ",").contains("0") {
                        debug("[AirPlay] Skip \(name): encryption types \(et) are not supported")
                        return nil
                    }
                }
                return device
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            guard let self, devices != self.devices else { return }
            self.devices = devices
            debug("[AirPlay] Devices: \(devices.map { $0.serviceName })")
            NotificationCenter.default.post(name: .AirPlayDevicesChanged, object: nil)
        }

        browser.stateUpdateHandler = { state in
            switch state {
                case let .failed(error):
                    warning("[AirPlay] Browser failed: \(error)")
                case let .waiting(error):
                    // e.g. PolicyDenied when the user did not allow local network access
                    warning("[AirPlay] Browser is waiting: \(error)")
                default:
                    break
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }
}

// MARK: - AirPlayPasswords

/// Asks the user for AirPlay passwords. Passwords are kept in memory only, for the life of the app.
enum AirPlayPasswords {
    private static var cache: [String: String] = [:]

    /// Returns the password for the device, asking the user if needed.
    /// Returns nil when the user cancels.
    static func password(for device: AirPlayDevice, previousFailed: Bool) -> String? {
        if Thread.isMainThread {
            return ask(device, previousFailed: previousFailed)
        }
        return DispatchQueue.main.sync { ask(device, previousFailed: previousFailed) }
    }

    private static func ask(_ device: AirPlayDevice, previousFailed: Bool) -> String? {
        if !previousFailed, let cached = cache[device.serviceName] {
            return cached
        }
        cache[device.serviceName] = nil

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("AirPlay password", comment: "AirPlay password dialog title")
        let text = previousFailed
            ? NSLocalizedString("The password for “%@” is incorrect. Try again.", comment: "AirPlay password dialog. %@ is device name")
            : NSLocalizedString("Enter the password for “%@”.", comment: "AirPlay password dialog. %@ is device name")
        alert.informativeText = String(format: text, device.name)
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "AirPlay password dialog button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "AirPlay password dialog button"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let password = field.stringValue
        cache[device.serviceName] = password
        return password
    }
}
