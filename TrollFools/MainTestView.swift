//
//  MainTestView.swift
//  TrollFools
//

import SwiftUI
import UniformTypeIdentifiers

struct MainTestView: View {
    @StateObject private var viewModel = DylibTestViewModel()
    @State private var isImporterPresented = false
    
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.bundle, .framework, .package, .zip, .data]
        if let dylibType = UTType(filenameExtension: "dylib") {
            types.append(dylibType)
        }
        if let debType = UTType(filenameExtension: "deb") {
            types.append(debType)
        }
        return types
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // แถบแสดงสถานะ
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.trailing, 5)
                    }
                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                
                // ลิสต์แสดงรายการ Dylib ที่มีอยู่
                List {
                    Section(header: Text("Dylibs / Frameworks ที่นำเข้าไว้")) {
                        if viewModel.items.isEmpty {
                            Text("ยังไม่มีไฟล์ที่นำเข้า กดปุ่ม '+' ด้านบนเพื่อเพิ่ม")
                                .font(.footnote)
                                .foregroundColor(.gray)
                        } else {
                            ForEach(viewModel.items) { item in
                                HStack {
                                    Image(systemName: item.type == .dylib ? "shippingbox.fill" : "cube.transparent.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                        Text(item.isLoaded ? "Status: Loaded (dlopen)" : "Status: Not Loaded")
                                            .font(.caption)
                                            .foregroundColor(item.isLoaded ? .green : .gray)
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        viewModel.toggleLoad(item: item)
                                    }) {
                                        Text(item.isLoaded ? "Unload" : "Load")
                                            .font(.subheadline)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(item.isLoaded ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                                            .foregroundColor(item.isLoaded ? .red : .blue)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            .navigationTitle("Test Dylib Loader")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isImporterPresented = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .onAppear {
                viewModel.refreshList()
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let selectedURL = urls.first else { return }
                    viewModel.importAndLoad(from: selectedURL)
                case .failure(let error):
                    viewModel.statusMessage = "เกิดข้อผิดพลาด: \(error.localizedDescription)"
                }
            }
        }
    }
}
