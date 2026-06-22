//
//  CRCShell.swift
//  Circe
//
//  Created by huangyimin on 2024/4/25.
//

import Foundation

class CRCShell: ObservableObject {
    @discardableResult
    static func run(_ binary: String, _ args: String..., directory: String? = nil) throws -> String {
        try run(binary, arguments: Array(args), directory: directory)
    }

    @discardableResult
    static func run(_ binary: String, arguments: [String], directory: String? = nil) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let directory = directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw String(decoding: output, as: UTF8.self)
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func signMacho(_ binary: URL) throws {
        try run("/usr/bin/codesign", "-fs-", binary.path)
    }
}

extension String: Error { }
