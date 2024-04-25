//
//  CRCError.swift
//  Circe
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

enum CRCError: Error {
    case infoPlistNotFound
    case waitInstallation
    case waitDownload
    case appEncrypted
    case appCorrupted
    case appProhibited
    case appMaliciousProhibited
}

extension CRCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .infoPlistNotFound:
            return NSLocalizedString("error.corruptedIPA", comment: "")
        case .waitInstallation:
            return NSLocalizedString("error.waitInstallation", comment: "")
        case .waitDownload:
            return NSLocalizedString("error.waitDownload", comment: "")
        case .appEncrypted:
            return NSLocalizedString("error.appEncrypted", comment: "")
        case .appCorrupted:
            return NSLocalizedString("error.appCorrupted", comment: "")
        case .appProhibited:
            return NSLocalizedString("error.appProhibited", comment: "")
        case .appMaliciousProhibited:
            return NSLocalizedString("error.appMaliciousProhibited", comment: "")
        }
    }
}
