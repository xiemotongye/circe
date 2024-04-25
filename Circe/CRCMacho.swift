//
//  CRCMacho.swift
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

class CRCMacho {
    static func convertMacho(_ path: String) throws {
        var binary = try Data(contentsOf: URL(fileURLWithPath: path))
        try replaceVersionCommand(&binary)
    }
    
    static func replaceVersionCommand(_ binary: inout Data) throws {
        var macCatalystCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_IOSSIMULATOR),
                                                       minos: 0x000b0000,
                                                       sdk: 0x000e0000,
                                                       ntools: 0)

        try replaceLastCommand(&binary, satisfy: {data, shouldSwap in
            let loadCommand = data.extract(load_command.self,
                                           offset: data.startIndex,
                                           swap: shouldSwap ? swap_load_command:nil)
            return [UInt32(LC_VERSION_MIN_IPHONEOS),
                    UInt32(LC_VERSION_MIN_MACOSX),
                    UInt32(LC_BUILD_VERSION)]
                .contains(loadCommand.cmd)

        }, with: {shouldSwap in
            if shouldSwap {
                swap_build_version_command(&macCatalystCommand, NX_BigEndian)
            }
            return Data(bytes: &macCatalystCommand, count: MemoryLayout<build_version_command>.size)
        }, atEnd: true)
    }

    static func replaceLastCommand(_ binary: inout Data,
                                   satisfy isTargetCommand: (Data, Bool) -> Bool,
                                   with getNewCommandData: (Bool) -> Data?,
                                   atEnd shouldAppend: Bool) throws {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        var shouldSwap = false

        var oldCommandStart = headerSize
        var oldCommandSize: UInt32 = 0

        let movedCommandsEnd = try iterateLoadCommands(binary: binary) { offset, needSwap in
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: needSwap ? swap_load_command:nil)
            if isTargetCommand(binary[offset ..< offset+Int(loadCommand.cmdsize)], needSwap) {
                oldCommandStart = offset
                oldCommandSize = loadCommand.cmdsize
                shouldSwap = needSwap
            }
            return false
        }
        if movedCommandsEnd != headerSize + Int(header.sizeofcmds) {
            print("Error while replacing load command: end of commands mismatch")
        }

        let oldCommandEnd = oldCommandStart + Int(oldCommandSize)
        guard let newCommandData = getNewCommandData(shouldSwap) else {
            return
        }
        let newCommandSize = UInt32(newCommandData.count)

        var resultingCommandsData = binary[oldCommandEnd..<movedCommandsEnd]
        if shouldAppend {
            resultingCommandsData.append(newCommandData)
        } else {
            resultingCommandsData.insert(contentsOf: newCommandData,
                                         at: resultingCommandsData.startIndex)
        }

        let injectionEnd = movedCommandsEnd - Int(oldCommandSize) + Int(newCommandSize)
        if injectionEnd > movedCommandsEnd {
            if let nonZero = binary[movedCommandsEnd ..< injectionEnd].first(where: {$0 != 0}) {
                print("Non zero value \(nonZero) found after load commands. Injection may overlap data section")
            }
        } else {
            binary.replaceSubrange(injectionEnd ..< movedCommandsEnd,
                                   with: Data(count: movedCommandsEnd - injectionEnd))
        }
        binary.replaceSubrange(oldCommandStart..<injectionEnd, with: resultingCommandsData)

        // Write new header data
        header.sizeofcmds -= oldCommandSize
        header.sizeofcmds += newCommandSize
        let newHeaderData = Data(bytes: &header, count: headerSize)
        binary.replaceSubrange(0..<headerSize, with: newHeaderData)
    }
    
    static func iterateLoadCommands(binary: Data, _ evaluate: (Int, Bool) -> Bool) throws -> Int {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        var offset = headerSize
        let shouldSwap = header.magic == MH_CIGAM_64
        if  shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
            print("Slim Mach-O has reversed byte order")
        }

        let allCommandsEnd = headerSize + Int(header.sizeofcmds)
        if allCommandsEnd >= binary.count || allCommandsEnd <= headerSize {
            print("Cannot iterate load commands: Mach-O file is corrupted(-1)")
            throw CRCError.appCorrupted
        }
        for index in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command:nil)
            let commandEnd = offset + Int(loadCommand.cmdsize)
            if commandEnd > allCommandsEnd || commandEnd <= offset {
                print("Cannot iterate load commands: Mach-O file is corrupted(\(index))")
                throw CRCError.appCorrupted
            }
            let terminated = evaluate(offset, shouldSwap)
            offset = commandEnd
            if terminated {
                break
            }
        }
        return offset
    }


}
