//
//  DylibItem.swift
//  TrollFools
//

import Foundation

struct DylibItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let type: ItemType
    var isLoaded: Bool
    
    enum ItemType {
        case dylib
        case framework
        
        var iconName: String {
            switch self {
            case .dylib: return "shippingbox.fill"
            case .framework: return "square.stack.3d.up.fill"
            }
        }
    }
}
