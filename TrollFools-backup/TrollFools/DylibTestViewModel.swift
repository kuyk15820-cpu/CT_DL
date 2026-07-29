//
//  DylibTestViewModel.swift
//  TrollFools
//

import Foundation
import Combine

final class DylibTestViewModel: ObservableObject {
    @Published var items: [DylibItem] = []
    @Published var statusMessage: String = "พร้อมทดสอบ"
    @Published var isLoading: Bool = false
    
    /// โหลดลิสต์ไฟล์ทั้งหมดที่มีอยู่ใน Directory ออกมาแสดง
    func refreshList() {
        let fileManager = FileManager.default
        let workingDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedPayloads", isDirectory: true)
        
        guard let files = try? fileManager.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil) else {
            return
        }
        
        var newItems: [DylibItem] = []
        for fileURL in files {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "dylib" {
                let isLoaded = DylibTestManager.shared.isLoaded(dylibURL: fileURL)
                newItems.append(DylibItem(name: fileURL.lastPathComponent, url: fileURL, type: .dylib, isLoaded: isLoaded))
            } else if ext == "framework" {
                let fwkName = fileURL.deletingPathExtension().lastPathComponent
                let binaryURL = fileURL.appendingPathComponent(fwkName)
                let isLoaded = DylibTestManager.shared.isLoaded(dylibURL: binaryURL)
                newItems.append(DylibItem(name: fileURL.lastPathComponent, url: binaryURL, type: .framework, isLoaded: isLoaded))
            }
        }
        
        DispatchQueue.main.async {
            self.items = newItems
        }
    }
    
    /// นำเข้าและสั่ง Sign + dlopen
    func importAndLoad(from url: URL) {
        isLoading = true
        statusMessage = "กำลังประมวลผลไฟล์ \(url.lastPathComponent)..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loadedURLs = try DylibImporter.shared.processAndLoadImportedFile(at: url)
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMessage = "SUCCESS: โหลดสำเร็จ (\(loadedURLs.count) ไฟล์)"
                    self.refreshList()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMessage = "ERROR: \(error.localizedDescription)"
                }
            }
        }
    }
    
    /// สลับการ Load / Unload
    func toggleLoad(item: DylibItem) {
        do {
            if item.isLoaded {
                try DylibTestManager.shared.unloadDylib(at: item.url)
                statusMessage = "Unload \(item.name) แล้ว"
            } else {
                try DylibTestManager.shared.prepareAndLoadDylib(at: item.url, forceSign: true)
                statusMessage = "Load \(item.name) เรียบร้อย!"
            }
            refreshList()
        } catch {
            statusMessage = "ERROR: \(error.localizedDescription)"
        }
    }
}
