//
//  main.swift
//  Circe
//
//  Created by huangyimin on 2024/4/23.
//

import Foundation

//guard CommandLine.arguments.count > 1 else {
//    fatalError("Please add a path to command!")
//}

//let outPath = CommandLine.arguments[1]
let outPath = "/Users/huangyimin/Downloads/bili-universal"
try CRCIpa.convertIpa(outPath)
