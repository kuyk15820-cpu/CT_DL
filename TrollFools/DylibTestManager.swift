//
//  DylibTestManager.swift
//  TrollFools
//
//  Created for Dylib Dynamic Testing inside Self-Process.
//

import Foundation
import MachOKit

/// ข้อผิดพลาดที่อาจเกิดขึ้นระหว่างการทดสอบ Dylib
enum DylibTestError: LocalizedError {
    case dylibNotFound(String)
    case signingFailed(String)
    case loadFailed(String)
    case unloadFailed(String)
    case dylibNotLoaded

    var errorDescription: String? {
        switch self {
        case let .dylibNotFound(path):
            return "ไม่พบไฟล์ dylib ที่ตำแหน่ง: \(path)"
        case let .signingFailed(reason):
            return "การเซ็นสัญญาด้วย ldid ล้มเหลว: \(reason)"
        case let .loadFailed(reason):
            return "dlopen ล้มเหลว: \(reason)"
        case let .unloadFailed(reason):
            return "dlclose ล้มเหลว: \(reason)"
        case .dylibNotLoaded:
            return "dylib ตัวนี้ยังไม่ได้ถูกโหลดเข้า Memory"
        }
    }
}

final class DylibTestManager {
    static let shared = DylibTestManager()

    /// เก็บ pointer handle ของ dylib แต่ละตัวที่ถูกโหลดอยู่ [Path: Handle]
    private(set) var loadedHandles: [URL: UnsafeMutableRawPointer] = [:]

    private init() {}

    // MARK: - Sign & Load Workflow

    /// ทดสอบ Sign dylib ด้วย ldid แล้วโหลดเข้า Process ตัวเองผ่าน dlopen
    /// - Parameters:
    ///   - dylibURL: ตำแหน่งของไฟล์ .dylib ที่ต้องการโหลด
    ///   - forceSign: บังคับให้เซ็น ad-hoc ใหม่ด้วย ldid เสมอหรือไม่
    /// - Returns: `UnsafeMutableRawPointer` pointer ของ handle ที่ได้จาก dlopen
    @discardableResult
    func prepareAndLoadDylib(at dylibURL: URL, forceSign: Bool = true) throws -> UnsafeMutableRawPointer {
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            throw DylibTestError.dylibNotFound(dylibURL.path)
        }

        // 1. ทำการ Pseudo-Sign ไฟล์ dylib ด้วย ldid ก่อน (อ้างอิงจาก InjectorV3+Command ของ TrollFools)
        try pseudoSignDylib(dylibURL, force: forceSign)

        // 2. เรียก dlopen เพื่อ Map dylib เข้า Memory ของแอปเราเอง
        return try loadDylib(at: dylibURL)
    }

    // MARK: - Core dlopen & dlclose

    /// เรียก dlopen เพื่อโหลด dylib เข้าแอปตัวเอง
    func loadDylib(at dylibURL: URL) throws -> UnsafeMutableRawPointer {
        let path = dylibURL.path

        // หากเคยโหลดไว้แล้ว ให้คืนค่า handle เดิม
        if let existingHandle = loadedHandles[dylibURL] {
            return existingHandle
        }

        // เรียกใช้ dlopen (RTLD_NOW: resolve symbols ทั้งหมดทันที)
        guard let handle = dlopen(path, RTLD_NOW) else {
            let errorMsg = String(cString: dlerror())
            throw DylibTestError.loadFailed(errorMsg)
        }

        loadedHandles[dylibURL] = handle
        print("[DylibTestManager] โหลด dylib สำเร็จ: \(dylibURL.lastPathComponent)")
        return handle
    }

    /// เรียก dlclose เพื่อปลด dylib ออกจาก Memory
    func unloadDylib(at dylibURL: URL) throws {
        guard let handle = loadedHandles[dylibURL] else {
            throw DylibTestError.dylibNotLoaded
        }

        let result = dlclose(handle)
        if result == 0 {
            loadedHandles.removeValue(forKey: dylibURL)
            print("[DylibTestManager] Unload dylib สำเร็จ: \(dylibURL.lastPathComponent)")
        } else {
            let errorMsg = String(cString: dlerror())
            throw DylibTestError.unloadFailed(errorMsg)
        }
    }

    /// ตรวจสอบว่า dylib ณ Path นี้ถูกโหลดอยู่หรือไม่
    func isLoaded(dylibURL: URL) -> Bool {
        return loadedHandles[dylibURL] != nil
    }

    // MARK: - ldid Helpers (ถอดโครงสร้างมาจาก InjectorV3)

    /// ใช้ ldid เพื่อลงนาม Ad-hoc ให้ dylib ก่อนนำมาสั่ง dlopen
    private func pseudoSignDylib(_ target: URL, force: Bool = false) throws {
        let ldidExecutableURL = findLdidExecutable()

        var hasCodeSign = false

        // ตรวจสอบโครงสร้าง Mach-O ว่ามี Code Signature แล้วหรือยังผ่าน MachOKit
        if let targetFile = try? MachOKit.loadFromFile(url: target) {
            switch targetFile {
            case let .machO(machOFile):
                for command in machOFile.loadCommands {
                    if case .codeSignature = command {
                        hasCodeSign = true
                        break
                    }
                }
            case let .fat(fatFile):
                if let machOFiles = try? fatFile.machOFiles() {
                    for machOFile in machOFiles {
                        for command in machOFile.loadCommands {
                            if case .codeSignature = command {
                                hasCodeSign = true
                                break
                            }
                        }
                    }
                }
            }
        }

        // หากมี Sign อยู่แล้วและไม่โดนขอบังคับ force ให้ข้ามไปได้เลย
        if hasCodeSign && !force {
            return
        }

        // สั่ง ldid -S [target] เพื่อลงนาม Ad-hoc
        // Dylib ทั่วไปใช้การลงนามแบบ -S ธรรมดา ไม่ต้องดึง entitlements ออกมาแบบไฟล์ Executable หลัก
        let retCode = try Execute.rootSpawn(
            binary: ldidExecutableURL.path,
            arguments: ["-S", target.path]
        )

        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            throw DylibTestError.signingFailed("ldid ออกด้วยค่านิรนาม code \(retCode)")
        }

        print("[DylibTestManager] ldid pseudo-sign สำเร็จ: \(target.lastPathComponent)")
    }

    /// ค้นหา ldid binary ตามสไตล์ TrollFools
    private func findLdidExecutable() -> URL {
        if let url = Bundle.main.url(forResource: "ldid", withExtension: nil) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent().appendingPathComponent("ldid")
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL.appendingPathComponent("ldid")
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        fatalError("ไม่พบไฟล์ executable 'ldid'")
    }
}
