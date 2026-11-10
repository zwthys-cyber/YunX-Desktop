// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UIKit

enum ThemeColor {
    static let initial = 0x3478f6
    static func color(_ value: Int) -> Color {
        let value = (0...0xffffff).contains(value) ? value : initial
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    static func value(_ color: Color) -> Int? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha), red.isFinite, green.isFinite, blue.isFinite else { return nil }
        func component(_ value: CGFloat) -> Int { max(0, min(255, Int((value * 255).rounded()))) }
        return (component(red) << 16) | (component(green) << 8) | component(blue)
    }
}
