//
//  AudioPage.swift
//  Radiola
//
//  Created by Aleksandr Sokolov on 10.12.2022.
//

import Cocoa

class AudioPage: PreferencesPage {
    private let deviceCombobox = NSPopUpButton()
    private let deviceLabel = NSLocalizedString("Device:", tableName: "Settings", comment: "Settings label")
    /* ****************************************
     *
     * ****************************************/
    override init() {
        super.init()
        title = NSLocalizedString("Audio", tableName: "Settings", comment: "Settings tab title")

        addRow(title: deviceLabel, rightView: deviceCombobox)

        deviceCombobox.target = self
        deviceCombobox.action = #selector(deviceChanged)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshDeviceCombo),
            name: Notification.Name.AudioDeviceChanged,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshDeviceCombo),
            name: Notification.Name.AirPlayDevicesChanged,
            object: nil)

        AirPlayBrowser.shared.start()
        refreshDeviceCombo()
    }

    /* ****************************************
     *
     * ****************************************/
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /* ****************************************
     *
     * ****************************************/
    @objc private func refreshDeviceCombo() {
        debug("[Settings] The list of audio devices has changed")
        AudioSytstem.debugAudioDevices(prefix: "[Settings]")

        let sel = settings.audioDevice

        deviceCombobox.removeAllItems()
        deviceCombobox.addItem(withTitle: "System Default Device")

        let devices = AudioSytstem.devices()
        for d in devices {
            deviceCombobox.addItem(withTitle: d.name)
            deviceCombobox.lastItem?.representedObject = d

            if d.UID == sel {
                deviceCombobox.select(deviceCombobox.lastItem)
            }
        }

        // AirPlay receivers. Keep the selected one in the list even if it is not visible right now.
        var airPlayDevices = AirPlayBrowser.shared.devices
        if let selected = AirPlayDevice(uid: sel), !airPlayDevices.contains(selected) {
            airPlayDevices.append(selected)
        }

        if !airPlayDevices.isEmpty {
            deviceCombobox.menu?.addItem(.separator())
        }

        for d in airPlayDevices {
            let title = String(format: NSLocalizedString("%@ (AirPlay)", comment: "Audio device name in settings. %@ is AirPlay device name"), d.name)
            deviceCombobox.addItem(withTitle: title)
            deviceCombobox.lastItem?.representedObject = d.uid

            if d.uid == sel {
                deviceCombobox.select(deviceCombobox.lastItem)
            }
        }

        if deviceCombobox.selectedItem == nil {
            deviceCombobox.selectItem(at: 0)
        }
    }

    /* ****************************************
     *
     * ****************************************/
    @objc private func deviceChanged(_ sender: Any) {
        let item = deviceCombobox.selectedItem?.representedObject
        let deviceUID = (item as? AudioDevice)?.UID ?? (item as? String)
        if settings.audioDevice != deviceUID {
            debug("[Settings] Select audio device \(deviceUID ?? "nil")")
            settings.audioDevice = deviceUID
            NotificationCenter.default.post(name: Notification.Name.SettingsChanged, object: nil)
        }
    }
}
