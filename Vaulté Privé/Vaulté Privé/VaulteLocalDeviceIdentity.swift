//
//  VaulteLocalDeviceIdentity.swift
//  Vaulté Privé
//

import Foundation
import UIKit

/// Stable per-install device id for Premium “trusted device” roster (local + relay metadata only).
enum VaulteLocalDeviceIdentity {
    private static let defaultsKey = "vaulteprive.device.instance_id"

    static var deviceId: UUID {
        if let s = UserDefaults.standard.string(forKey: defaultsKey),
           let u = UUID(uuidString: s) {
            return u
        }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: defaultsKey)
        return u
    }

    static var deviceMarketingName: String {
        UIDevice.current.model
    }
}
