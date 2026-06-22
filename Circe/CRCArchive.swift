//
//  CRCArchive.swift
//  Circe
//
//  Created by AI on 2026/5/21.
//

import Foundation

class CRCArchive {
    /// Convert a static archive (.a) from arm64 iOS to arm64 iOS Simulator.
    /// - Parameters:
    ///   - inputPath: Path to the input .a file (may be fat or thin)
    ///   - outputPath: Path to write the converted .a file
    static func convertArchive(_ inputPath: String, _ outputPath: String) throws {
        let fileManager = FileManager.default
        let tempDir = NSTemporaryDirectory() + "circe_arm2sim_\(ProcessInfo.processInfo.processIdentifier)"

        // Clean up any previous run
        try? fileManager.removeItem(atPath: tempDir)
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let thinPath = tempDir + "/thin_arm64.a"

        // Step 1: Extract arm64 slice (if fat binary)
        do {
            try CRCShell.run("/usr/bin/lipo", inputPath, "-thin", "arm64", "-output", thinPath)
        } catch {
            // Not a fat binary or only has arm64 — use as-is
            try fileManager.copyItem(atPath: inputPath, toPath: thinPath)
        }

        // Step 2: Extract .o files from the archive
        let extractDir = tempDir + "/objects"
        try fileManager.createDirectory(atPath: extractDir, withIntermediateDirectories: true)

        try CRCShell.run("/usr/bin/ar", arguments: ["x", thinPath], directory: extractDir)

        // Step 3: Convert each .o file
        let objects = try fileManager.contentsOfDirectory(atPath: extractDir)
            .filter { $0.hasSuffix(".o") }

        for obj in objects {
            let objPath = extractDir + "/" + obj
            try CRCMacho.convertMacho(objPath)
        }

        // Step 4: Repackage into output .a
        let outputURL = URL(fileURLWithPath: outputPath)
        // Ensure output directory exists
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var arArgs = ["rcs", outputPath]
        arArgs += objects.map { extractDir + "/" + $0 }
        try CRCShell.run("/usr/bin/ar", arguments: arArgs)
    }
}
