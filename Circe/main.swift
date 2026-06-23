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
    // Detect static archives by content. Handles both thin archives (magic "!<arch>\n"
    // at the very start) and fat archives (FAT_MAGIC / FAT_CIGAM header that wraps
    // per-arch `ar` slices). Returns true if the inner content is `ar` format.
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    guard let data = try? fh.read(upToCount: 4096) else { return false }
    let arMagic: [UInt8] = [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A] // "!<arch>\n"
    if data.starts(with: arMagic) {
        return true
    }
    // Fat header magic
    let fatMagic: [[UInt8]] = [[0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]]
    guard data.count >= 4 else { return false }
    let head = Array(data.prefix(4))
    guard fatMagic.contains(head) else { return false }
    // Scan for "!<arch>\n" anywhere in the first 4KB (fat wrapper places slices at offsets).
    if data.count < arMagic.count { return false }
    for i in 0...(data.count - arMagic.count) {
        if Array(data[i..<(i + arMagic.count)]) == arMagic {
            return true
        }
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
