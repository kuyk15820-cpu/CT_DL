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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fileManager = FileManager.default
            let workingDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImportedPayloads", isDirectory: true)
            
            guard let files = try? fileManager.contentsOfDirectory(
                at: workingDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                DispatchQueue.main.async {
                    self.items = []
                }
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
                    
                    // เช็คสถานะการโหลดผ่านตัว Binary URL
                    let isLoaded = DylibTestManager.shared.isLoaded(dylibURL: binaryURL)
                    
                    // เก็บ URL สำหรับ Execute (binaryURL)
                    newItems.append(DylibItem(name: fileURL.lastPathComponent, url: binaryURL, type: .framework, isLoaded: isLoaded))
                }
            }
            
            DispatchQueue.main.async {
                self.items = newItems
            }
        }
    }
    
    /// นำเข้าและสั่ง Sign + dlopen
    func importAndLoad(from url: URL) {
        isLoading = true
        statusMessage = "กำลังประมวลผลไฟล์ \(url.lastPathComponent)..."
        
        // 🔥 เพิ่มการจัดการ Security Scoped Resource สำหรับไฟล์ที่เลือกมาจาก Document Picker
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            guard let self = self else { return }
            do {
                // 1. เรียกเตรียมไฟล์จาก DylibImporter
                let dylibURLs = try DylibImporter.shared.prepareDylibs(from: url)
                
                // 2. ส่งไฟล์ที่สกัดได้ไป Sign และ Load ผ่าน DylibTestManager
                for dylibURL in dylibURLs {
                    try DylibTestManager.shared.prepareAndLoadDylib(at: dylibURL, forceSign: true)
                }
                
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMessage = "SUCCESS: โหลดสำเร็จ (\(dylibURLs.count) ไฟล์)"
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
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let message: String
                if item.isLoaded {
                    try DylibTestManager.shared.unloadDylib(at: item.url)
                    message = "Unload \(item.name) แล้ว"
                } else {
                    // โหลดผ่าน Manager (ซึ่งรองรับทั้ง ct_bypass + dlopen แล้ว)
                    try DylibTestManager.shared.prepareAndLoadDylib(at: item.url, forceSign: true)
                    message = "Load \(item.name) เรียบร้อย!"
                }
                
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMessage = message
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
}
