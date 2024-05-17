//
//  CRCInfoPlist.swift
//  Circe
//
//  Created by huangyimin on 2024/5/15.
//
import Foundation

public class CRCInfoPlist {
    public let url: URL
    
    private static let deviceConvertMap = [
        "iphoneos":     "iphonesimulator",
        "iPhoneOS":     "iPhoneSimulator",
        "watchos":      "watchsimulator",
        "WatchOS":      "WatchSimulator",
        "appletvos":    "appletvsimulator",
        "AppleTVOS":    "AppleTVSimulator",
        "xros":         "xrsimulator",
        "XROS":         "XRSimulator",
    ]
    
    fileprivate var rawStorage: NSMutableDictionary

    public init(contentsOf url: URL) {
        do {
            rawStorage = try NSMutableDictionary(contentsOf: url, error: ())
            self.url = url
        } catch {
            rawStorage = NSMutableDictionary()
            self.url = URL(fileURLWithPath: "")
        }
    }

    private init(url: URL, rawStorage: NSMutableDictionary) {
        self.url = url
        self.rawStorage = rawStorage
    }

    /// Write an XML-serialized representation of this info to the given URL
    func write(toURL url: URL) throws {
        try rawStorage.write(to: url)
    }

    /// Overwrites the file this AppInfo was loaded from
    func write() throws {
        try write(toURL: url)
    }
    
    static func convertInfoPlist(_ path: String) throws {
        let plistURL = URL(fileURLWithPath: path)
        var appInfo = CRCInfoPlist(contentsOf:plistURL)
        for key in deviceConvertMap.keys {
            // convert value of DTPlatformName
            if (appInfo.platformName.contains(key)) {
                appInfo.platformName = deviceConvertMap[key]!
            }
            // convert value of DTSDKName
            if (appInfo.sdkName.contains(key)) {
                appInfo.sdkName = appInfo.sdkName.replacingOccurrences(of: key, with: deviceConvertMap[key]!)
            }
            // convert value of CFBundleSupportedPlatforms
            var newPlatforms : [String] = []
            for platform in appInfo.bundleSupportedPlatforms {
                if platform.contains(key) {
                    newPlatforms.append(deviceConvertMap[key]!)
                } else {
                    newPlatforms.append(platform)
                }
            }
            appInfo.bundleSupportedPlatforms = newPlatforms
        }
        try appInfo.write()
    }
    
    subscript(string index: String) -> String? {
        get {
            rawStorage[index] as? String
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(object index: String) -> NSObject? {
        get {
            rawStorage[index] as? NSObject
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(dictionary index: String) -> NSMutableDictionary? {
        get {
            rawStorage[index] as? NSMutableDictionary
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(strings index: String) -> [String]? {
        get {
            rawStorage[index] as? [String]
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(array index: String) -> NSMutableArray? {
        get {
            rawStorage[index] as? NSMutableArray
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(numbers index: String) -> [NSNumber]? {
        get {
            rawStorage[index] as? [NSNumber]
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(ints index: String) -> [Int]? {
        get {
            rawStorage[index] as? [Int]
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(doubles index: String) -> [Double]? {
        get {
            rawStorage[index] as? [Double]
        }
        set {
            rawStorage[index] = newValue
        }
    }

    subscript(bool index: String) -> Bool? {
        get {
            rawStorage[index] as? Bool
        }
        set {
            rawStorage[index] = newValue
        }
    }

    var minimumOSVersion: String {
        get {
            self[string: "MinimumOSVersion"] ?? ""
        }
        set {
            self[string: "MinimumOSVersion"] = newValue
        }
    }

    var bundleName: String {
        if self[string: "CFBundleName"] == nil || self[string: "CFBundleName"] == "" {
            return self[string: "CFBundleDisplayName"] ?? ""
        } else {
            return self[string: "CFBundleName"] ?? ""
        }
    }

    var displayName: String {
        if self[string: "CFBundleDisplayName"] == nil || self[string: "CFBundleDisplayName"] == "" {
            return self[string: "CFBundleName"] ?? ""
        } else {
            return self[string: "CFBundleDisplayName"] ?? ""
        }
    }

    var bundleIdentifier: String {
        get {
            self[string: "CFBundleIdentifier"] ?? ""
        }
        set {
            self[string: "CFBundleIdentifier"] = newValue
        }
    }

    var executableName: String {
        get {
            self[string: "CFBundleExecutable"] ?? ""
        }
        set {
            self[string: "CFBundleExecutable"] = newValue
        }
    }

    var bundleVersion: String {
        get {
            self[string: "CFBundleShortVersionString"] ?? ""
        }
        set {
            self[string: "CFBundleShortVersionString"] = newValue
        }
    }
    
    var platformName: String {
        get {
            self[string: "DTPlatformName"] ?? ""
        }
        set {
            self[string: "DTPlatformName"] = newValue
        }
    }
    
    var sdkName: String {
        get {
            self[string: "DTSDKName"] ?? ""
        }
        set {
            self[string: "DTSDKName"] = newValue
        }
    }
    
    var bundleSupportedPlatforms: [String] {
        get {
            self[strings: "CFBundleSupportedPlatforms"] ?? []
        }
        set {
            self[strings: "CFBundleSupportedPlatforms"] = newValue
        }
    }
}
