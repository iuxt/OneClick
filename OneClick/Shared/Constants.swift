//
//  Constants.swift
//  OneClick
//
//  Created by 李旭 on 2024/9/25.
//

import Foundation


public enum Constants {
    nonisolated static let HomedirPath = Utils.getRealHomeDir()
    /// The identifier for the settings window.
    static let settingsWindowID = "oneclick-settings"
    nonisolated static let protectedDirs = [
        HomedirPath + "/Desktop/",
        HomedirPath + "/Desktop/danger/",
        HomedirPath + "/Applications/",
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]
    static let suitName = SharedAppGroup.identifier

}
