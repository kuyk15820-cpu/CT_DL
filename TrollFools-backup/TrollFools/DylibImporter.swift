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
    
    /// ประมวลผลไฟล์ที่ผู้ใช้เลือกจาก Document Picker
    /// - Parameter url: URL ของไฟล์ (.dylib, .deb, .framework)
    /// - Returns: รายการ URL ของไฟล์ Mach-O (.dylib หรือ executable ใน framework) ที่สกัดและ Sign พร้อมสั่ง dlopen แล้ว
    func processAndLoadImportedFile(at url: URL) throws -> [URL] {
        // ให้สิทธิ์เข้าถึงไฟล์ชั่วคราวจาก Document Picker (Security Scoped URL)
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
            
            // หา Binary หลักภายใน .framework
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
        
        // สั่ง Sign ด้วย ldid และ dlopen ผ่าน DylibTestManager ทุกตัวที่สกัดออกมาได้
        var loadedURLs: [URL] = []
        for machOURL in extractedMachOURLs {
            try DylibTestManager.shared.prepareAndLoadDylib(at: machOURL, forceSign: true)
            loadedURLs.append(machOURL)
        }
        
        return loadedURLs
    }
    
    // MARK: - DEB Extraction Helper
    
    /// สกัดไฟล์ .deb โดยใช้ ar / tar หรือการลอกไฟล์ data.tar
    private func extractDebPayload(debURL: URL, destinationDir: URL) throws -> [URL] {
        let tempExtractDir = destinationDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempExtractDir)
        }
        
        // 1. สกัดไฟล์ .deb ด้วย ar (หรือ tar) ผ่าน Execute.rootSpawn ของ TrollFools
        let arBinary = findExecutable("ar")
        let arRet = try Execute.rootSpawn(
            binary: arBinary.path,
            arguments: ["x", debURL.path, "--output", tempExtractDir.path]
        )
        guard case let .exit(code) = arRet, code == EXIT_SUCCESS else {
            throw Error.generic("แตกไฟล์ deb ด้วย ar ไม่สำเร็จ (Exit code: \(arRet))")
        }
        
        // 2. ค้นหา data.tar.* (อาจเป็น data.tar.gz, data.tar.xz, หรือ data.tar.zstd)
        let contents = try FileManager.default.contentsOfDirectory(at: tempExtractDir, includingPropertiesForKeys: nil)
        guard let dataTarURL = contents.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) else {
            throw Error.generic("ไม่พบ data.tar ในไฟล์ .deb")
        }
        
        // 3. แตกไฟล์ data.tar ด้วย tar
        let tarBinary = findExecutable("tar")
        let tarRet = try Execute.rootSpawn(
            binary: tarBinary.path,
            arguments: ["-xf", dataTarURL.path, "-C", tempExtractDir.path]
        )
        guard case let .exit(tarCode) = tarRet, tarCode == EXIT_SUCCESS else {
            throw Error.generic("แตกไฟล์ \(dataTarURL.lastPathComponent) ไม่สำเร็จ")
        }
        
        // 4. สแกนหา .dylib และ .framework ที่สกัดออกมาได้
        var resultURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: tempExtractDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let itemURL as URL in enumerator {
                let ext = itemURL.pathExtension.lowercased()
                if ext == "dylib" {
                    let destDylib = destinationDir.appendingPathComponent(itemURL.lastPathComponent)
                    try? FileManager.default.removeItem(at: destDylib)
                    try FileManager.default.copyItem(at: itemURL, to: destDylib)
                    resultURLs.append(destDylib)
                } else if ext == "framework" {
                    let destFwk = destinationDir.appendingPathComponent(itemURL.lastPathComponent)
                    try? FileManager.default.removeItem(at: destFwk)
                    try FileManager.default.copyItem(at: itemURL, to: destFwk)
                    
                    let fwkName = itemURL.deletingPathExtension().lastPathComponent
                    let binaryURL = destFwk.appendingPathComponent(fwkName)
                    if FileManager.default.fileExists(atPath: binaryURL.path) {
                        resultURLs.append(binaryURL)
                    }
                    enumerator.skipDescendants()
                }
            }
        }
        
        guard !resultURLs.isEmpty else {
            throw Error.generic("ไม่พบไฟล์ .dylib หรือ .framework ภายใน package .deb")
        }
        
        return resultURLs
    }
    
    private func findExecutable(_ name: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        fatalError("Unable to locate executable \(name)")
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
