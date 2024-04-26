//
//  CRCError.swift
//  Circe
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

enum CRCError: Error {
    case appCorrupted
    case appNotfound
    case failedToStripBinary
}

extension CRCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .appCorrupted:
            return NSLocalizedString("error.appCorrupted", comment: "")
        case .appNotfound:
            return NSLocalizedString("error.appNotfound", comment: "")
        case .failedToStripBinary:
            return NSLocalizedString("error.failedToStripBinary", comment: "")
        }
    }
}
