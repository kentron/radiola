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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshDeviceCombo),
            name: Notification.Name.SettingsChanged,
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
        let outputs = AudioOutputs.list()

        deviceCombobox.removeAllItems()
        for (i, output) in outputs.enumerated() {
            if output.isAirPlay && !outputs[i - 1].isAirPlay {
                deviceCombobox.menu?.addItem(.separator())
            }

            deviceCombobox.addItem(withTitle: output.title)
            deviceCombobox.lastItem?.representedObject = output.uid

            if output.uid != nil && output.uid == sel {
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
        AudioOutputs.select(uid: deviceCombobox.selectedItem?.representedObject as? String)
    }
}
