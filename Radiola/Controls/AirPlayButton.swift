//
//  AirPlayButton.swift
//  Radiola
//
//  Created by Alex Sokolov on 07.03.2026.
//

import AppKit
import IOKit.ps

// MARK: - AudioOutputs

/// The list of outputs Radiola can play to: the system default device,
/// CoreAudio devices and AirPlay receivers. Shared by the AirPlay button and the Audio settings page.
enum AudioOutputs {
    struct Output {
        /// Value for `settings.audioDevice`, nil means the system default device
        let uid: String?
        let title: String
        let isAirPlay: Bool
    }

    static func list() -> [Output] {
        var res = [Output(uid: nil, title: NSLocalizedString("System Default Device", comment: "Audio device name"), isAirPlay: false)]

        for d in AudioSytstem.devices() {
            res.append(Output(uid: d.UID, title: d.name, isAirPlay: false))
        }

        // Keep the selected AirPlay receiver in the list even if it is not visible right now
        var airPlayDevices = AirPlayBrowser.shared.devices
        if let selected = AirPlayDevice(uid: settings.audioDevice), !airPlayDevices.contains(selected) {
            airPlayDevices.append(selected)
        }

        for d in airPlayDevices {
            let title = String(format: NSLocalizedString("%@ (AirPlay)", comment: "Audio device name in settings. %@ is AirPlay device name"), d.name)
            res.append(Output(uid: d.uid, title: title, isAirPlay: true))
        }

        return res
    }

    static func select(uid: String?) {
        guard settings.audioDevice != uid else { return }
        debug("[Settings] Select audio device \(uid ?? "nil")")
        settings.audioDevice = uid
        NotificationCenter.default.post(name: Notification.Name.SettingsChanged, object: nil)
    }
}

// MARK: - AirPlayButton

/// Shows a menu with this Mac and the AirPlay receivers.
/// Apple's AVRoutePickerView can't connect to AirPlay 1 receivers, Radiola streams to them itself.
final class AirPlayButton: NSButton {
    /* ****************************************
     *
     * ****************************************/
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    /* ****************************************
     *
     * ****************************************/
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /* ****************************************
     *
     * ****************************************/
    private func setup() {
        image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: NSLocalizedString("AirPlay", comment: "AirPlay button tooltip"))
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        toolTip = NSLocalizedString("AirPlay", comment: "AirPlay button tooltip")
        target = self
        action = #selector(showMenu)

        for name in [Notification.Name.AirPlayDevicesChanged, .SettingsChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: name, object: nil)
        }

        AirPlayBrowser.shared.start()
        update()
    }

    /* ****************************************
     * Visible when there is an AirPlay receiver to choose,
     * highlighted when Radiola plays to one.
     * ****************************************/
    @objc private func update() {
        let isAirPlay = AirPlayDevice(uid: settings.audioDevice) != nil
        isHidden = !isAirPlay && AirPlayBrowser.shared.devices.isEmpty
        contentTintColor = isAirPlay ? .controlAccentColor : nil
    }

    /* ****************************************
     * Like the AirPlay menu of Control Center and Music.app:
     * this Mac and the AirPlay receivers.
     * ****************************************/
    @objc private func showMenu() {
        let menu = NSMenu()
        let current = AirPlayDevice(uid: settings.audioDevice)

        let mac = NSMenuItem(title: Host.current().localizedName ?? NSLocalizedString("This Mac", comment: "AirPlay menu item"),
                             action: #selector(macSelected), keyEquivalent: "")
        mac.target = self
        mac.image = NSImage(systemSymbolName: AirPlayButton.isLaptop ? "laptopcomputer" : "desktopcomputer", accessibilityDescription: nil)
        mac.state = current == nil ? .on : .off
        menu.addItem(mac)

        var devices = AirPlayBrowser.shared.devices
        if let current, !devices.contains(current) {
            devices.append(current)
        }

        if !devices.isEmpty {
            menu.addItem(.separator())
        }

        for d in devices {
            let item = NSMenuItem(title: d.name, action: #selector(airPlaySelected), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uid
            item.image = NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: nil)
            item.state = d == current ? .on : .off
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }

    /* ****************************************
     * The Mac output that was in use before switching to AirPlay
     * ****************************************/
    private static var previousMacOutput: String?

    /* ****************************************
     *
     * ****************************************/
    @objc private func airPlaySelected(_ sender: NSMenuItem) {
        if AirPlayDevice(uid: settings.audioDevice) == nil {
            AirPlayButton.previousMacOutput = settings.audioDevice
        }
        AudioOutputs.select(uid: sender.representedObject as? String)
    }

    /* ****************************************
     * Go back to the output used before AirPlay, the system default if unknown
     * ****************************************/
    @objc private func macSelected(_ sender: NSMenuItem) {
        guard AirPlayDevice(uid: settings.audioDevice) != nil else { return }
        AudioOutputs.select(uid: AirPlayButton.previousMacOutput)
    }

    /* ****************************************
     *
     * ****************************************/
    private static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return desc?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}
