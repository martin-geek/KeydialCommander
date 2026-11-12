import CoreGraphics
import Foundation

@main
struct LayoutTests {
    static func main() {
        let identifiers = Set(Control.all.map(\.id))
        precondition(identifiers == Set((1...18).map { "BUTTON_\($0)" } +
                                        ["DIAL_CLICK", "DIAL_CW", "DIAL_CCW"]))
        precondition(Orientation.upperLeft.clockwise.clockwise.clockwise.clockwise == .upperLeft)
        precondition(Orientation.upperLeft.clockwise == .upperRight)
        precondition(Orientation.lowerRight.clockwise == .lowerLeft)
        let dial = Control.all.first { $0.id == "DIAL_CLICK" }!
        let corners: [(Orientation, Bool, Bool)] = [
            (.upperLeft, true, true), (.upperRight, false, true),
            (.lowerRight, false, false), (.lowerLeft, true, false),
        ]
        for (orientation, left, top) in corners {
            let bounds = CGRect(origin: .zero, size: orientation.size)
            let placedDial = orientation.place(dial.frame)
            precondition((placedDial.midX < bounds.midX) == left)
            precondition((placedDial.midY < bounds.midY) == top)
            let rectangles = Control.all.map { orientation.place($0.frame) }
            for (index, rect) in rectangles.enumerated() {
                precondition(bounds.contains(rect))
                precondition(!rectangles.prefix(index).contains { $0.intersects(rect) })
            }
        }
        print("All four dial positions preserve every control and rotate without overlaps.")
    }
}
