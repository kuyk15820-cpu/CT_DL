//
//  DylibImporter.swift
//  TrollFools
//
//  Created for Dynamic File Import & Load (dylib, deb, framework)
//

import Foundation
import UniformTypeIdentifiers

final class DylibImporter {
    static let shared = DylibImporter()
    
    private init() {}
    
    /// สกัดและเตรียมไฟล์ Mach-O จาก Document Picker (.dylib, .deb, .framework)
    func prepareDylibs(from url: URL) throws -> [URL] {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        
        let ext = url.pathExtension.lowercased()
        var extractedMachOURLs: [URL] = []
        
        let fileManager = FileManager.default
        let workingDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedPayloads", isDirectory: true)
        
        try? fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
        
        switch ext {
        case "dylib":
            let destURL = workingDir.appendingPathComponent(url.lastPathComponent)
            try? fileManager.removeItem(at: destURL)
            try fileManager.copyItem(at: url, to: destURL)
            extractedMachOURLs.append(destURL)
            
        case "framework":
            let destURL = workingDir.appendingPathComponent(url.lastPathComponent)
            try? fileManager.removeItem(at: destURL)
            try fileManager.copyItem(at: url, to: destURL)
            
            let frameworkName = url.deletingPathExtension().lastPathComponent
            let binaryURL = destURL.appendingPathComponent(frameworkName)
            if fileManager.fileExists(atPath: binaryURL.path) {
                extractedMachOURLs.append(binaryURL)
            } else {
                throw Error.generic("ไม่พบไฟล์ Binary หลักภายใน Framework: \(frameworkName)")
            }
            
        case "deb":
            let extractedURLs = try extractDebPayload(debURL: url, destinationDir: workingDir)
            extractedMachOURLs.append(contentsOf: extractedURLs)
            
        default:
            throw Error.generic("ไม่รองรับไฟล์ประเภท .\(ext)")
        }
        
        guard !extractedMachOURLs.isEmpty else {
            throw Error.generic("ไม่พบไฟล์ dylib หรือ framework ที่สามารถสกัดได้")
        }
        
        return extractedMachOURLs
    }
    
    // MARK: - DEB Extraction Helper
    
    private func extractDebPayload(debURL: URL, destinationDir: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let tempExtractDir = destinationDir.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempExtractDir)
        }
        
        // 1. สกัดไฟล์ .deb ด้วย ar โดยระบุ Output Directory ใน Argument
        let arBinary = findExecutable("ar")
        
        let arRet = try Execute.rootSpawn(
            binary: arBinary.path,
            arguments: ["x", debURL.path, "--output", tempExtractDir.path]
        )
        
        // หาก ar x ปฏิเสธ --output ให้ใช้ fallback ย้ายไฟล์ deb ไปแตกข้างในแทน
        if case let .exit(code) = arRet, code != EXIT_SUCCESS {
            let tempDebURL = tempExtractDir.appendingPathComponent("pkg.deb")
            try? fileManager.copyItem(at: debURL, to: tempDebURL)
            
            _ = try Execute.rootSpawn(
                binary: arBinary.path,
                arguments: ["x", tempDebURL.path]
            )
        }
        
        // 2. ค้นหา data.tar.*
        let contents = try fileManager.contentsOfDirectory(at: tempExtractDir, includingPropertiesForKeys: nil)
        guard let dataTarURL = contents.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) else {
            throw Error.generic("ไม่พบ data.tar ภายในไฟล์ .deb")
        }
        
        // 3. แตกไฟล์ data.tar ด้วย tar เข้าโฟลเดอร์ tempExtractDir
        let tarBinary = findExecutable("tar")
        let tarRet = try Execute.rootSpawn(
            binary: tarBinary.path,
            arguments: ["-xf", dataTarURL.path, "-C", tempExtractDir.path]
        )
        guard case let .exit(tarCode) = tarRet, tarCode == EXIT_SUCCESS else {
            throw Error.generic("แตกไฟล์ \(dataTarURL.lastPathComponent) ไม่สำเร็จ")
        }
        
        // 4. สแกนหา .dylib และ .framework
        var resultURLs: [URL] = []
        if let enumerator = fileManager.enumerator(at: tempExtractDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let itemURL as URL in enumerator {
                let ext = itemURL.pathExtension.lowercased()
                if ext == "dylib" {
                    let destDylib = destinationDir.appendingPathComponent(itemURL.lastPathComponent)
                    try? fileManager.removeItem(at: destDylib)
                    try fileManager.copyItem(at: itemURL, to: destDylib)
                    resultURLs.append(destDylib)
                } else if ext == "framework" {
                    let destFwk = destinationDir.appendingPathComponent(itemURL.lastPathComponent)
                    try? fileManager.removeItem(at: destFwk)
                    try fileManager.copyItem(at: itemURL, to: destFwk)
                    
                    let fwkName = itemURL.deletingPathExtension().lastPathComponent
                    let binaryURL = destFwk.appendingPathComponent(fwkName)
                    if fileManager.fileExists(atPath: binaryURL.path) {
                        resultURLs.append(binaryURL)
                    }
                    enumerator.skipDescendants()
                }
            }
        }
        
        guard !resultURLs.isEmpty else {
            throw Error.generic("ไม่พบไฟล์ .dylib หรือ .framework ภายในแพ็กเกจ .deb")
        }
        
        return resultURLs
    }
    
    private func findExecutable(_ name: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        fatalError("ไม่พบไฟล์ executable '\(name)' ในระบบ")
    }
}

extension DylibImporter {
    enum Error: LocalizedError {
        case generic(String)
        var errorDescription: String? {
            switch self {
            case .generic(let msg): return msg
            }
        }
    }
}
