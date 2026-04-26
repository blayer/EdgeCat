import SwiftUI

// 1:1 port of android-app/.../ui/common/chat/MessageBubbleShape.kt — a rounded
// rectangle with one of the speaker-side corners squared off (left for agent,
// right for user) so the bubble visually points to its sender.

struct MessageBubbleShape: Shape {
    var radius: CGFloat = 18
    /// True when the bubble belongs to the agent — squares off the bottom-left;
    /// false (user) squares off the bottom-right.
    var hardCornerAtLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        let bottomLeftR = hardCornerAtLeft ? 0 : r
        let bottomRightR = hardCornerAtLeft ? r : 0

        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                    radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRightR))
        if bottomRightR > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - bottomRightR, y: rect.maxY - bottomRightR),
                        radius: bottomRightR, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeftR, y: rect.maxY))
        if bottomLeftR > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bottomLeftR, y: rect.maxY - bottomLeftR),
                        radius: bottomLeftR, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                    radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
