//
//  main.swift
//  Circe
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

guard CommandLine.arguments.count > 1 else {
    fatalError("Usage: Circe <input.a> <output.a>  OR  Circe <ipa_directory>  OR  Circe <input_macho> <output_macho>")
}

let path = CommandLine.arguments[1]

func isArArchive(_ path: String) -> Bool {
    // Detect static archives by content. Handles both:
    // - Thin archives: magic "!<arch>\n" at offset 0
    // - Fat archives: FAT_MAGIC header wrapping per-arch `ar` slices
    //   (the ar magic may be far beyond the first 4KB due to large slices)
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    guard let header = try? fh.read(upToCount: 8) else { return false }

    let arMagic: [UInt8] = [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A] // "!<arch>\n"
    if Array(header) == arMagic {
        return true
    }

    // Check for fat binary wrapping ar slices
    guard header.count >= 4 else { return false }
    let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
    let isFat = (magic == 0xCAFEBABE || magic == 0xBEBAFECA)
    guard isFat else { return false }

    // Read fat_header to find first arm64 slice offset, then check if that
    // slice starts with ar magic.
    try? fh.seek(toOffset: 0)
    guard let fatData = try? fh.read(upToCount: 4096) else { return false }
    guard fatData.count >= 8 else { return false }

    let shouldSwap = (magic == 0xBEBAFECA)
    var nfatArch = fatData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
    if shouldSwap { nfatArch = nfatArch.byteSwapped }

    var offset = 8 // after fat_header
    for _ in 0..<min(nfatArch, 8) {
        guard offset + 20 <= fatData.count else { break }
        // fat_arch: cputype(4) cpusubtype(4) offset(4) size(4) align(4)
        var sliceOffset = fatData.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt32.self) }
        if shouldSwap { sliceOffset = sliceOffset.byteSwapped }

        // Seek to slice and check for ar magic
        try? fh.seek(toOffset: UInt64(sliceOffset))
        if let sliceHeader = try? fh.read(upToCount: 8), Array(sliceHeader) == arMagic {
            return true
        }
        offset += 20
    }
    return false
}

if path.hasSuffix(".a") {
    guard CommandLine.arguments.count > 2 else {
        fatalError("Usage: Circe <input.a> <output.a>")
    }
    let outputPath = CommandLine.arguments[2]
    try CRCArchive.convertArchive(path, outputPath)
} else if CommandLine.arguments.count > 2 {
    // <input> <output>: copy input to output, convert in-place at output.
    // Detect whether the binary is a static archive (`ar`) — common for static
    // frameworks where `Foo.framework/Foo` is actually a fat `ar` archive — or
    // a Mach-O binary.
    let outputPath = CommandLine.arguments[2]
    let outputURL = URL(fileURLWithPath: outputPath)
    let outputDir = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    if isArArchive(path) {
        try CRCArchive.convertArchive(path, outputPath)
    } else {
        if FileManager.default.fileExists(atPath: outputPath) {
            try FileManager.default.removeItem(atPath: outputPath)
        }
        try FileManager.default.copyItem(atPath: path, toPath: outputPath)
        try CRCMacho.convertMacho(outputPath)
    }
} else {
    try CRCIpa.convertIpa(path)
}
