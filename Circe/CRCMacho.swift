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
    ///   - sign: When true (default), re-sign with ad-hoc signature after conversion.
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
        let needsShift = injectionEnd > movedCommandsEnd
        let extraBytes = needsShift ? (injectionEnd - movedCommandsEnd) : 0

        if needsShift {
            // New command is larger — insert padding to push section data forward.
            binary.insert(contentsOf: Data(count: extraBytes), at: movedCommandsEnd)
        } else {
            binary.replaceSubrange(injectionEnd ..< movedCommandsEnd,
                                   with: Data(count: movedCommandsEnd - injectionEnd))
        }
        binary.replaceSubrange(oldCommandStart..<(oldCommandStart + resultingCommandsData.count), with: resultingCommandsData)

        // Write new header data
        header.sizeofcmds -= oldCommandSize
        header.sizeofcmds += newCommandSize
        let newHeaderData = Data(bytes: &header, count: headerSize)
        binary.replaceSubrange(0..<headerSize, with: newHeaderData)

        // If we shifted section data, update all file offsets in load commands.
        if needsShift {
            var secOffset = headerSize
            let updatedHeader = binary.extract(mach_header_64.self)
            var ncmds = updatedHeader.ncmds
            let lcShouldSwap = (updatedHeader.magic == MH_CIGAM_64)
            if lcShouldSwap {
                var h = updatedHeader
                swap_mach_header_64(&h, NXHostByteOrder())
                ncmds = h.ncmds
            }
            for _ in 0..<ncmds {
                var lc = binary.extract(load_command.self, offset: secOffset)
                if lcShouldSwap { swap_load_command(&lc, NXHostByteOrder()) }
                if lc.cmd == UInt32(LC_SEGMENT_64) {
                    let segHeaderSize = MemoryLayout<segment_command_64>.size
                    var seg = binary.extract(segment_command_64.self, offset: secOffset)
                    if lcShouldSwap { swap_segment_command_64(&seg, NXHostByteOrder()) }
                    if seg.fileoff > 0 { seg.fileoff += UInt64(extraBytes) }
                    if lcShouldSwap { swap_segment_command_64(&seg, NX_BigEndian) }
                    binary.replaceSubrange(secOffset..<(secOffset + segHeaderSize),
                                           with: Data(bytes: &seg, count: segHeaderSize))
                    if lcShouldSwap { swap_segment_command_64(&seg, NXHostByteOrder()) }
                    var secOff2 = secOffset + segHeaderSize
                    for _ in 0..<seg.nsects {
                        let secSize = MemoryLayout<section_64>.size
                        var sec = binary.extract(section_64.self, offset: secOff2)
                        if lcShouldSwap { swap_section_64(&sec, 1, NXHostByteOrder()) }
                        if sec.offset > 0 { sec.offset += UInt32(extraBytes) }
                        if sec.reloff > 0 { sec.reloff += UInt32(extraBytes) }
                        if lcShouldSwap { swap_section_64(&sec, 1, NX_BigEndian) }
                        binary.replaceSubrange(secOff2..<(secOff2 + secSize),
                                               with: Data(bytes: &sec, count: secSize))
                        secOff2 += secSize
                    }
                } else if lc.cmd == UInt32(LC_SYMTAB) {
                    var symtab = binary.extract(symtab_command.self, offset: secOffset)
                    if lcShouldSwap { swap_symtab_command(&symtab, NXHostByteOrder()) }
                    if symtab.symoff > 0 { symtab.symoff += UInt32(extraBytes) }
                    if symtab.stroff > 0 { symtab.stroff += UInt32(extraBytes) }
                    if lcShouldSwap { swap_symtab_command(&symtab, NX_BigEndian) }
                    binary.replaceSubrange(secOffset..<(secOffset + MemoryLayout<symtab_command>.size),
                                           with: Data(bytes: &symtab, count: MemoryLayout<symtab_command>.size))
                } else if lc.cmd == UInt32(LC_DYSYMTAB) {
                    var dysymtab = binary.extract(dysymtab_command.self, offset: secOffset)
                    if lcShouldSwap { swap_dysymtab_command(&dysymtab, NXHostByteOrder()) }
                    if dysymtab.tocoff > 0 { dysymtab.tocoff += UInt32(extraBytes) }
                    if dysymtab.modtaboff > 0 { dysymtab.modtaboff += UInt32(extraBytes) }
                    if dysymtab.extrefsymoff > 0 { dysymtab.extrefsymoff += UInt32(extraBytes) }
                    if dysymtab.indirectsymoff > 0 { dysymtab.indirectsymoff += UInt32(extraBytes) }
                    if dysymtab.extreloff > 0 { dysymtab.extreloff += UInt32(extraBytes) }
                    if dysymtab.locreloff > 0 { dysymtab.locreloff += UInt32(extraBytes) }
                    if lcShouldSwap { swap_dysymtab_command(&dysymtab, NX_BigEndian) }
                    binary.replaceSubrange(secOffset..<(secOffset + MemoryLayout<dysymtab_command>.size),
                                           with: Data(bytes: &dysymtab, count: MemoryLayout<dysymtab_command>.size))
                } else if lc.cmd == UInt32(LC_LINKER_OPTIMIZATION_HINT) || lc.cmd == UInt32(LC_DATA_IN_CODE) {
                    var led = binary.extract(linkedit_data_command.self, offset: secOffset)
                    if lcShouldSwap { swap_linkedit_data_command(&led, NXHostByteOrder()) }
                    if led.dataoff > 0 { led.dataoff += UInt32(extraBytes) }
                    if lcShouldSwap { swap_linkedit_data_command(&led, NX_BigEndian) }
                    binary.replaceSubrange(secOffset..<(secOffset + MemoryLayout<linkedit_data_command>.size),
                                           with: Data(bytes: &led, count: MemoryLayout<linkedit_data_command>.size))
                }
                secOffset += Int(lc.cmdsize)
            }
        }
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
