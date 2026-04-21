import SwiftUI
import UIKit
import simd

enum SemanticSurfaceClass: String, CaseIterable, Hashable, Identifiable, Sendable {
    case floor
    case wall
    case ceiling
    case table
    case seat
    case window
    case door
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floor: return "Floor"
        case .wall: return "Wall"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .seat: return "Seat"
        case .window: return "Window"
        case .door: return "Door"
        case .none: return "Unlabeled"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .floor: return UIColor.systemGreen
        case .wall: return UIColor.systemBlue
        case .ceiling: return UIColor.systemOrange
        case .table: return UIColor.systemPurple
        case .seat: return UIColor.systemPink
        case .window: return UIColor.systemCyan
        case .door: return UIColor.systemBrown
        case .none: return UIColor.systemGray
        }
    }

    var color: Color {
        Color(uiColor)
    }

    static var defaultVisible: Set<SemanticSurfaceClass> {
        Set(Self.allCases.filter { $0 != .none })
    }
}

struct SemanticMeshGroup: Sendable {
    let semanticClass: SemanticSurfaceClass
    let vertices: [SIMD3<Float>]
}

struct SemanticMeshChunk: Identifiable, Sendable {
    let id: UUID
    let groups: [SemanticMeshGroup]
}
