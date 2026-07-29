import Foundation

public enum DylibLoadError: LocalizedError {
    case fileNotFound
    case unsupportedType
    case extractionFailed
    case signFailed
    case dlopenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "ไม่พบไฟล์ที่เลือก"
        case .unsupportedType:
            return "รองรับเฉพาะไฟล์ .dylib, .deb, .zip หรือ .framework"
        case .extractionFailed:
            return "ไม่สามารถแตกไฟล์ .deb / .zip ได้"
        case .signFailed:
            return "ไม่สามารถทำ Code Sign (ldid) บน dylib ได้"
        case .dlopenFailed(let message):
            return "dlopen ล้มเหลว: \(message)"
        }
    }
}

public class DylibImporter {
    public static let shared = DylibImporter()

    private init() {}

    /// ค้นหา ldid executable จากใน Bundle
    private var ldidURL: URL? {
        if let url = Bundle.main.url(forResource: "ldid", withExtension: nil) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg).deletingLastPathComponent().appendingPathComponent("ldid")
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        return nil
    }

    /// ขั้นตอนที่ 1 & 2: Preprocess และแตกไฟล์ถ้าเป็น deb/zip
    public func prepareDylibs(from sourceURL: URL) throws -> [URL] {
        let fileManager = FileManager.default

        // ขอสิทธิ์อ่านไฟล์ข้าม Sandbox (Security Scoped Bookmark)
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DylibLoadError.fileNotFound
        }

        let ext = sourceURL.pathExtension.lowercased()

        // ถ้าส่ง .dylib หรือ .framework มาตรงๆ
        if ext == "dylib" || ext == "framework" {
            let targetURL = getDestinationURL(for: sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            return [targetURL]
        }

        // ถ้าเป็น .deb หรือ .zip ให้ใช้ InjectorV3.main.preprocessAssets ช่วยแตกไฟล์
        if ext == "deb" || ext == "zip" {
            let extractedURLs = try InjectorV3.main.preprocessAssets([sourceURL])
            var finalDylibs = [URL]()

            for url in extractedURLs {
                let targetURL = getDestinationURL(for: url.lastPathComponent)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try? fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: url, to: targetURL)
                finalDylibs.append(targetURL)
            }

            guard !finalDylibs.isEmpty else {
                throw DylibLoadError.extractionFailed
            }
            return finalDylibs
        }

        throw DylibLoadError.unsupportedType
    }

    /// ขั้นตอนที่ 3: สั่ง ldid -S เพื่อ Sign dylib ก่อนสั่ง dlopen
    public func signDylib(at url: URL) throws {
        guard let ldid = ldidURL else {
            // ถ้าไม่พบ ldid ให้ข้ามไป
            return
        }

        let receipt = AuxiliaryExecute.spawn(
            command: ldid.path,
            args: ["-S", url.path]
        )

        if case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS {
            return
        } else {
            throw DylibLoadError.signFailed
        }
    }

    /// ขั้นตอนที่ 4: สั่ง dlopen โหลดเข้า Memory Process
    public func loadDylib(at url: URL) throws -> UnsafeMutableRawPointer {
        // Sign ก่อนทุกครั้ง
        try? signDylib(at: url)

        // เคลียร์ dlerror
        dlerror()

        // เรียก dlopen
        let handle = dlopen(url.path, RTLD_NOW)

        if let handle = handle {
            return handle
        } else {
            let errorMsg = dlerror().map { String(cString: $0) } ?? "Unknown error"
            throw DylibLoadError.dlopenFailed(errorMsg)
        }
    }

    private func getDestinationURL(for filename: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dylibDir = documents.appendingPathComponent("ImportedDylibs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dylibDir, withIntermediateDirectories: true)
        return dylibDir.appendingPathComponent(filename)
    }
}
