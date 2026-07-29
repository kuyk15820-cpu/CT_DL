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
    case executableNotFound(String)
    case signingFailed(String)
    case ctBypassFailed(String)
    case loadFailed(String)
    case unloadFailed(String)
    case dylibNotLoaded

    var errorDescription: String? {
        switch self {
        case let .dylibNotFound(path):
            return "ไม่พบไฟล์ dylib ที่ตำแหน่ง: \(path)"
        case let .executableNotFound(name):
            return "ไม่พบไฟล์ Helper Executable: \(name)"
        case let .signingFailed(reason):
            return "การเซ็นสัญญาด้วย ldid ล้มเหลว: \(reason)"
        case let .ctBypassFailed(reason):
            return "การทำ CoreTrust Bypass (ct_bypass) ล้มเหลว: \(reason)"
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

    /// ทดสอบ Sign, Bypass CoreTrust และโหลด dylib เข้า Process ตัวเองผ่าน dlopen
    /// - Parameters:
    ///   - dylibURL: ตำแหน่งของไฟล์ .dylib ที่ต้องการโหลด
    ///   - forceSign: บังคับให้เซ็นใหม่และทำ ct_bypass เสมอหรือไม่
    ///   - teamID: Team ID สำหรับการทำ ct_bypass (หากไม่ใส่จะดึงจาก Bundle หรือใช้ค่า Default)
    /// - Returns: `UnsafeMutableRawPointer` pointer ของ handle ที่ได้จาก dlopen
    @discardableResult
    func prepareAndLoadDylib(
        at dylibURL: URL,
        forceSign: Bool = true,
        teamID: String? = nil
    ) throws -> UnsafeMutableRawPointer {
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            throw DylibTestError.dylibNotFound(dylibURL.path)
        }

        // 1. ทำการ Pseudo-Sign ไฟล์ dylib ด้วย ldid
        try pseudoSignDylib(dylibURL, force: forceSign)

        // 2. 🔥 ขั้นตอนสำคัญ: ทำ CoreTrust Bypass (ct_bypass) เพื่อให้ Kernel ยอมรับ dlopen
        let targetTeamID = teamID ?? getAppTeamID()
        try applyCoreTrustBypass(dylibURL, teamID: targetTeamID)

        // 3. ปรับสิทธิ์ Owner ของไฟล์ (chown 33:33 / mobile:mobile) ป้องกัน permission denied
        try? changeOwnerToMobile(dylibURL)

        // 4. เรียก dlopen เพื่อ Map dylib เข้า Memory ของแอป
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

    // MARK: - TrollFools Core Signing & Bypass Helpers

    /// ใช้ ldid เพื่อลงนาม Ad-hoc ให้ dylib
    private func pseudoSignDylib(_ target: URL, force: Bool = false) throws {
        let ldidExecutableURL = try findExecutable("ldid")

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

        if hasCodeSign && !force {
            return
        }

        // สั่ง ldid -S [target] เพื่อลงนาม Ad-hoc
        let retCode = try Execute.rootSpawn(
            binary: ldidExecutableURL.path,
            arguments: ["-S", target.path]
        )

        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            throw DylibTestError.signingFailed("ldid exited with code \(retCode)")
        }

        print("[DylibTestManager] ldid pseudo-sign สำเร็จ: \(target.lastPathComponent)")
    }

    /// 🔥 ใช้ ct_bypass เพื่อทำ CoreTrust Bypass (จุดที่แก้ให้ dlopen ผ่าน)
    private func applyCoreTrustBypass(_ target: URL, teamID: String) throws {
        let ctBypassURL = try findExecutable("ct_bypass")

        // รันคำสั่ง: ct_bypass -r -i [target.path] -t [teamID]
        let retCode = try Execute.rootSpawn(
            binary: ctBypassURL.path,
            arguments: ["-r", "-i", target.path, "-t", teamID]
        )

        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            throw DylibTestError.ctBypassFailed("ct_bypass exited with code \(retCode)")
        }

        print("[DylibTestManager] ct_bypass สำเร็จสำหรับ TeamID (\(teamID)): \(target.lastPathComponent)")
    }

    /// เปลี่ยน Owner ของไฟล์ dylib ให้เป็น mobile/installd (UID 33)
    private func changeOwnerToMobile(_ target: URL) throws {
        guard let chownURL = try? findExecutable("chown") else { return }
        _ = try? Execute.rootSpawn(
            binary: chownURL.path,
            arguments: ["33:33", target.path]
        )
    }

    // MARK: - Utility Helpers

    /// ค้นหา Helper Binary ต่างๆ (ldid, ct_bypass, chown)
    private func findExecutable(_ name: String) throws -> URL {
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
        throw DylibTestError.executableNotFound(name)
    }

    /// ดึง Team ID ของตัวแอปปัจจุบัน
    private func getAppTeamID() -> String {
        if let teamID = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String {
            return teamID.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return "0000000000" // Default fallback Team ID สำหรับ TrollStore
    }
}
