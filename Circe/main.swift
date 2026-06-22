//
//  main.swift
//  Circe
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

guard CommandLine.arguments.count > 1 else {
    fatalError("Usage: Circe <path.a> <output.a>  OR  Circe <ipa_directory>")
}

let path = CommandLine.arguments[1]

if path.hasSuffix(".a") {
    guard CommandLine.arguments.count > 2 else {
        fatalError("Usage: Circe <input.a> <output.a>")
    }
    let outputPath = CommandLine.arguments[2]
    try CRCArchive.convertArchive(path, outputPath)
} else {
    try CRCIpa.convertIpa(path)
}
