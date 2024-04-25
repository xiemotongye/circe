//
//  CRCIpa.swift
//  Circe
//
//  Created by huangyimin on 2024/4/25.
//

import Foundation

class CRCIpa {
    static func blackMagic(_ path: String) throws  {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: path + "/Payload")
        let appFiles = contents.filter { $0.hasSuffix(".app") }
        if appFiles.count == 0 {
            throw CRCError.appNotfound
        } else if appFiles.count > 1 {
            throw CRCError.appCannotDecide
        } else {
            let appPath = appFiles[0]
            let appName = appPath.split(separator: ".")[0]
            try CRCMacho.convertMacho(path + "/Payload/" + appName + ".app/" + appName)
        }
    }
}
