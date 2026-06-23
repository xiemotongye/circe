//
//  CRCMacho.swift
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

class CRCMacho {
    /// Converts a Mach-O binary in place from arm64 iOS to arm64 iOS Simulator.
    /// - Parameters:
    ///   - path: Path to the Mach-O file.
    ///   - sign: When true, re-sign the converted binary with an ad-hoc code
    ///     signature. Disable when converting transient `.o` members extracted
    ///     from a static archive — they will be re-archived and signed (if at
    ///     all) at the final framework binary level, and codesigning each `.o`
    ///     causes thousands of fork() calls that can exhaust process limits.
    static func convertMacho(_ path: String, sign: Bool = true) throws {
        let binaryURL = URL(fileURLWithPath: path)
        var binary = try Data(contentsOf: binaryURL)
        try stripBinary(&binary)
        try replaceVersionCommand(&binary)
        try FileManager.default.removeItem(at: binaryURL)
        try binary.write(to: binaryURL)
        if sign {
            try CRCShell.signMacho(binaryURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: binaryURL.path)
    }
    
    static func stripBinary(_ binary: inout Data) throws {
        var header = binary.extract(fat_header.self)
        var offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == FAT_CIGAM

        if header.magic == FAT_MAGIC || header.magic == FAT_CIGAM {
            // Make sure the endianness is correct
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }

            for _ in 0..<header.nfat_arch {
                var arch = binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch(&arch, 1, NXHostByteOrder())
                }

                if arch.cputype == CPU_TYPE_ARM64 {
                    print("Found ARM64 arch in fat binary")

                    binary = binary
                        .subdata(in: Int(arch.offset)..<Int(arch.offset+arch.size))

                    return
                }

                offset += Int(MemoryLayout.size(ofValue: arch))
            }

            throw CRCError.failedToStripBinary
        }
    }
    
    static func replaceVersionCommand(_ binary: inout Data) throws {
        try replaceLastCommand(&binary, satisfy: {data, shouldSwap in
            let loadCommand = data.extract(load_command.self,
                                           offset: data.startIndex,
                                           swap: shouldSwap ? swap_load_command:nil)
            return [UInt32(LC_VERSION_MIN_IPHONEOS),
                    UInt32(LC_BUILD_VERSION)]
                .contains(loadCommand.cmd)

        }, with: {data, shouldSwap, offset in
            var minos, sdk: UInt32
            var newLoadCommand : build_version_command
            let loadCommand = data.extract(load_command.self,
                                           offset: offset,
                                           swap: shouldSwap ? swap_load_command:nil)
            if loadCommand.cmd == UInt32(LC_VERSION_MIN_IPHONEOS) {
                let oldLoadCommand = data.extract(version_min_command.self,
                                                  offset: offset,
                                                  swap: shouldSwap ? swap_version_min_command:nil)
                minos = oldLoadCommand.version
                sdk = oldLoadCommand.sdk
                newLoadCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_IOSSIMULATOR),
                                                       minos: minos,
                                                       sdk: sdk,
                                                       ntools: 0)
            } else {
                let oldLoadCommand = data.extract(build_version_command.self,
                                                  offset: offset,
                                                  swap: shouldSwap ? swap_build_version_command:nil)
                minos = oldLoadCommand.minos
                sdk = oldLoadCommand.sdk
                newLoadCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_IOSSIMULATOR),
                                                       minos: minos,
                                                       sdk: sdk,
                                                       ntools: 0)
            }
            if shouldSwap {
                swap_build_version_command(&newLoadCommand, NX_BigEndian)
            }
            return Data(bytes: &newLoadCommand, count: MemoryLayout<build_version_command>.size)
        }, atEnd: true)
    }

    static func replaceLastCommand(_ binary: inout Data,
                                   satisfy isTargetCommand: (Data, Bool) -> Bool,
                                   with getNewCommandData: (Data, Bool, Int) -> Data?,
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
        guard let newCommandData = getNewCommandData(binary, shouldSwap, oldCommandStart) else {
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
