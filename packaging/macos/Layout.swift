import CoreGraphics
import Foundation

enum Orientation: String, CaseIterable, Identifiable {
    case upperLeft = "Upper left"
    case upperRight = "Upper right"
    case lowerRight = "Lower right"
    case lowerLeft = "Lower left"

    var id: Self { self }
    var sideways: Bool { self == .upperRight || self == .lowerLeft }

    var size: CGSize {
        sideways ? CGSize(width: 6.45, height: 4) : CGSize(width: 4, height: 6.45)
    }

    func place(_ rect: CGRect) -> CGRect {
        switch self {
        case .upperLeft: return rect
        case .upperRight:
            return CGRect(x: 6.45 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case .lowerRight:
            return CGRect(x: 4 - rect.maxX, y: 6.45 - rect.maxY, width: rect.width, height: rect.height)
        case .lowerLeft:
            return CGRect(x: rect.minY, y: 4 - rect.maxX, width: rect.height, height: rect.width)
        }
    }
}

struct Control: Identifiable {
    let id: String
    let label: String
    let frame: CGRect
    var dialCenter: Bool { id == "DIAL_CLICK" }

    static let all: [Control] = {
        var controls = (1...18).map { button -> Control in
            let index = button - 1
            let row = index < 16 ? index / 4 : 4
            let column = index < 16 ? index % 4 : (button == 17 ? 0 : 2)
            return Control(id: "BUTTON_\(button)", label: "\(button)",
                           frame: CGRect(x: CGFloat(column) + 0.055, y: CGFloat(row) + 1.50,
                                         width: button == 17 ? 1.89 : 0.89,
                                         height: button == 16 ? 1.89 : 0.89))
        }
        controls += [
            Control(id: "DIAL_CLICK", label: "Press", frame: CGRect(x: 0.22, y: 0.15, width: 1.14, height: 1.14)),
            Control(id: "DIAL_CCW", label: "↺", frame: CGRect(x: 1.49, y: 0.41, width: 0.68, height: 0.61)),
            Control(id: "DIAL_CW", label: "↻", frame: CGRect(x: 2.29, y: 0.41, width: 0.68, height: 0.61)),
        ]
        return controls
    }()

    static func name(_ id: String) -> String {
        switch id {
        case "DIAL_CLICK": return "Dial press"
        case "DIAL_CCW": return "Dial counterclockwise"
        case "DIAL_CW": return "Dial clockwise"
        default: return id.split(separator: "+").map {
            "Button " + $0.replacingOccurrences(of: "BUTTON_", with: "")
        }.joined(separator: " + ")
        }
    }
}
