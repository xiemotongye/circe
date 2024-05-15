//
//  CRCIpa.swift
//  Circe
//
//  Created by huangyimin on 2024/4/25.
//

import Foundation

class CRCIpa {
    static func convertIpa(_ path: String) throws  {
        let fileManager = FileManager.default
        var payloadPath: String
        if fileManager.fileExists(atPath: path + "/Payload") {
            payloadPath = path + "/Payload"
        } else {
            payloadPath = path
        }
        var contents = try fileManager.contentsOfDirectory(atPath: payloadPath)
        let appFiles = contents.filter { $0.hasSuffix(".app") }
        if appFiles.count == 0 {
            throw CRCError.appNotfound
        } else {
            for appFile in appFiles {
                let appMachO = appFile.split(separator: ".")[0]
                let appPath = payloadPath + "/" + appFile
                
                // convert dylibs & frameworks
                let frameworkPath = appPath + "/Frameworks"
                if fileManager.fileExists(atPath: frameworkPath) {
                    contents = try fileManager.contentsOfDirectory(atPath: frameworkPath)
                    let dylibs = contents.filter { $0.hasSuffix(".dylib") }
                    for dylib in dylibs {
                        try CRCMacho.convertMacho(frameworkPath + "/" + dylib)
                    }
                    let frameworks = contents.filter { $0.hasSuffix(".framework") }
                    for framework in frameworks {
                        let frameworkMachO = framework.split(separator: ".")[0]
                        try CRCMacho.convertMacho(frameworkPath + "/" + framework + "/" + frameworkMachO)
                    }
                }
                // convert plugins
                let pluginPath = appPath + "/PlugIns"
                if fileManager.fileExists(atPath: pluginPath) {
                    contents = try fileManager.contentsOfDirectory(atPath: pluginPath)
                    let appexs = contents.filter { $0.hasSuffix(".appex") }
                    for appex in appexs {
                        let appexMachO = appex.split(separator: ".")[0]
                        try CRCMacho.convertMacho(pluginPath + "/" + appex + "/" + appexMachO)
                    }
                }
                
                // convert main Mach-O
                try CRCMacho.convertMacho(appPath + "/" + appMachO)
            }
        }
    }
}
