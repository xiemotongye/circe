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

        // Step 2: Extract .o files from the archive.
        //
        // `ar` archives can contain duplicate member names (a single library
        // built for multiple bit depths often ships e.g. two `cdef_tmpl.c.o`
        // entries — one per template instantiation). A plain `ar x` silently
        // overwrites the earlier file with the later one, losing roughly half
        // of the templated `.o`s and the symbols they define.
        //
        // macOS `ar` (BSD) does not support `-N <occurrence>` to disambiguate,
        // so we parse the archive format directly and write each member to a
        // unique filename of our choosing.
        let extractDir = tempDir + "/objects"
        try fileManager.createDirectory(atPath: extractDir, withIntermediateDirectories: true)

        let objects = try extractArchiveMembers(archivePath: thinPath, into: extractDir)

        for obj in objects {
            let objPath = extractDir + "/" + obj
            try CRCMacho.convertMacho(objPath, sign: false)
        }

        // Step 4: Repackage into output .a
        let outputURL = URL(fileURLWithPath: outputPath)
        // Ensure output directory exists
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Resolve to an absolute path so subsequent `ar` invocations launched
        // with `directory: extractDir` find it correctly.
        let absoluteOutputPath = outputURL.standardizedFileURL.path
        // Ensure we start with no pre-existing archive (so `ar -q` actually
        // creates a fresh one).
        if fileManager.fileExists(atPath: absoluteOutputPath) {
            try fileManager.removeItem(atPath: absoluteOutputPath)
        }

        // Archives can contain thousands of .o members. Passing every member
        // path on the command line risks blowing past ARG_MAX (the kernel
        // raises E2BIG and Foundation surfaces it as an NSException from
        // NSConcreteTask). Instead, run `ar` from inside the extract dir
        // (relative names) and batch the inputs.
        let batchSize = 256
        var first = true
        var index = 0
        while index < objects.count {
            let end = min(index + batchSize, objects.count)
            let batch = Array(objects[index..<end])
            // First batch: `rcS` creates the archive without an index.
            // Subsequent batches: `qS` quick-append, also without an index.
            // After all batches: `s` to regenerate the symbol table.
            let op = first ? "rcS" : "qS"
            var args = [op, absoluteOutputPath]
            args += batch
            try CRCShell.run("/usr/bin/ar", arguments: args, directory: extractDir)
            first = false
            index = end
        }
        // Regenerate the archive symbol table at the end (equivalent to `ranlib`).
        try CRCShell.run("/usr/bin/ar", arguments: ["s", absoluteOutputPath])
    }

    /// Parses a BSD/macOS `ar` archive and writes each `.o` member to a unique
    /// file in `outputDir`. Returns the list of written filenames in archive
    /// order. Non-`.o` members (symbol table, ranlib index) are skipped.
    ///
    /// Members whose name collides with an earlier member are renamed with a
    /// `_dup<occurrence>_` prefix so `ar x` can later repackage them without
    /// clobbering. Without this, ~half of the `.o` files in templated archives
    /// (e.g. dav1d's per-bit-depth `*_tmpl.c.o`) silently disappear.
    private static func extractArchiveMembers(archivePath: String, into outputDir: String) throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: archivePath))
        let magic = "!<arch>\n"
        guard data.count >= magic.count,
              String(data: data.prefix(magic.count), encoding: .ascii) == magic else {
            throw NSError(domain: "CRCArchive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not an ar archive: \(archivePath)"])
        }

        var offset = magic.count
        var seenCounts: [String: Int] = [:]
        var nameTotals: [String: Int] = [:]
        var rawMembers: [(name: String, payload: Data)] = []

        while offset + 60 <= data.count {
            // Member header: 16 bytes name, 12 mtime, 6 uid, 6 gid, 8 mode,
            // 10 size, 2 magic ("`\n").
            let nameField = String(data: data[offset..<offset+16], encoding: .ascii) ?? ""
            let sizeField = String(data: data[offset+48..<offset+58], encoding: .ascii) ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces)) else { break }
            let headerEnd = offset + 60

            var name = nameField.trimmingCharacters(in: .whitespaces)
            var dataStart = headerEnd
            var dataLen = size

            // BSD-style long name: header name reads "#1/<len>" and the real
            // name occupies the first <len> bytes of the data section.
            if name.hasPrefix("#1/"), let nameLen = Int(name.dropFirst(3)) {
                let nameBytes = data[headerEnd..<(headerEnd + nameLen)]
                if let extracted = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .ascii) {
                    name = extracted.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                }
                dataStart = headerEnd + nameLen
                dataLen = size - nameLen
            }

            // Strip trailing slash on SystemV-style entries ("foo.o/").
            if name.hasSuffix("/") {
                name = String(name.dropLast())
            }

            let payload = data[dataStart..<(dataStart + dataLen)]

            // Skip the archive symbol table (BSD: __.SYMDEF[ SORTED], or empty
            // names for ranlib indexes).
            if name == "__.SYMDEF" || name == "__.SYMDEF SORTED" || name.isEmpty || name == "/" || name == "//" {
                // Advance past this entry (with 2-byte alignment) and continue.
                offset = headerEnd + size
                if size % 2 != 0 { offset += 1 }
                continue
            }

            rawMembers.append((name: name, payload: Data(payload)))
            // macOS filesystems (APFS by default) are case-insensitive, so
            // members like `Resize.o` and `resize.o` would clobber each
            // other on disk even though the archive treats them as distinct.
            // Track collisions case-insensitively so the rename logic below
            // catches them too.
            nameTotals[name.lowercased(), default: 0] += 1

            offset = headerEnd + size
            if size % 2 != 0 { offset += 1 }
        }

        var resultNames: [String] = []
        for member in rawMembers {
            guard member.name.hasSuffix(".o") else { continue }
            let key = member.name.lowercased()
            seenCounts[key, default: 0] += 1
            let occurrence = seenCounts[key]!

            let writeName: String
            if (nameTotals[key] ?? 0) > 1 {
                writeName = "_dup\(occurrence)_" + member.name
            } else {
                writeName = member.name
            }
            let writePath = outputDir + "/" + writeName
            try member.payload.write(to: URL(fileURLWithPath: writePath))
            resultNames.append(writeName)
        }
        return resultNames
    }
}
