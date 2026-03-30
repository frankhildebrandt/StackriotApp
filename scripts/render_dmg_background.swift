import AppKit
import Foundation

let arguments = CommandLine.arguments

guard arguments.count == 2 else {
    fputs("usage: swift scripts/render_dmg_background.swift <output-path>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let canvasSize = NSSize(width: 900, height: 540)
let iconURL = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset/appicon_512@2x.png")

guard let appIcon = NSImage(contentsOf: iconURL) else {
    fputs("failed to load app icon at \(iconURL.path)\n", stderr)
    exit(1)
}

let image = NSImage(size: canvasSize)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("failed to create drawing context\n", stderr)
    exit(1)
}

let bounds = CGRect(origin: .zero, size: canvasSize)
let background = NSColor(calibratedRed: 11.0 / 255.0, green: 18.0 / 255.0, blue: 32.0 / 255.0, alpha: 1.0)
context.setFillColor(background.cgColor)
context.fill(bounds)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 14.0 / 255.0, green: 28.0 / 255.0, blue: 48.0 / 255.0, alpha: 1.0),
    NSColor(calibratedRed: 24.0 / 255.0, green: 52.0 / 255.0, blue: 82.0 / 255.0, alpha: 1.0),
    NSColor(calibratedRed: 10.0 / 255.0, green: 20.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0),
])!
gradient.draw(in: NSBezierPath(roundedRect: bounds.insetBy(dx: -80, dy: -80), xRadius: 32, yRadius: 32), angle: -35)

let glowColors = [
    NSColor(calibratedRed: 77.0 / 255.0, green: 217.0 / 255.0, blue: 213.0 / 255.0, alpha: 0.18).cgColor,
    NSColor(calibratedRed: 251.0 / 255.0, green: 146.0 / 255.0, blue: 60.0 / 255.0, alpha: 0.14).cgColor,
]
let glowCenters = [
    CGPoint(x: 180, y: 420),
    CGPoint(x: 760, y: 130),
]

for (index, center) in glowCenters.enumerated() {
    let glowRect = CGRect(x: center.x - 170, y: center.y - 170, width: 340, height: 340)
    let colors = [glowColors[index], NSColor.clear.cgColor] as CFArray
    let locations: [CGFloat] = [0, 1]
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let radial = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        context.drawRadialGradient(
            radial,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: 170,
            options: [.drawsAfterEndLocation]
        )
    }
    context.stroke(glowRect.insetBy(dx: 34, dy: 34), width: 0)
}

let panelRect = NSRect(x: 38, y: 38, width: 824, height: 464)
let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 28, yRadius: 28)
NSColor(calibratedWhite: 1.0, alpha: 0.05).setFill()
panelPath.fill()
NSColor(calibratedWhite: 1.0, alpha: 0.08).setStroke()
panelPath.lineWidth = 1
panelPath.stroke()

let panelGradient = NSGradient(colors: [
    NSColor(calibratedWhite: 1.0, alpha: 0.05),
    NSColor(calibratedWhite: 1.0, alpha: 0.015),
])!
panelGradient.draw(in: panelPath, angle: -90)

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1.0),
]

let wrappedParagraph = NSMutableParagraphStyle()
wrappedParagraph.lineBreakMode = .byWordWrapping
wrappedParagraph.alignment = .left

let bodyAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 0.92),
    .paragraphStyle: wrappedParagraph,
]

let captionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.86, alpha: 0.72),
    .paragraphStyle: wrappedParagraph,
]

NSAttributedString(string: "Stackriot installieren", attributes: titleAttributes)
    .draw(at: NSPoint(x: 84, y: 392))
NSAttributedString(
    string: "Ziehe die App in den Programme-Ordner.",
    attributes: bodyAttributes
).draw(with: NSRect(x: 84, y: 320, width: 430, height: 62))
NSAttributedString(
    string: "Git-Worktrees, IDE-Start, KI-Agenten und Run-Konsole.",
    attributes: captionAttributes
).draw(with: NSRect(x: 84, y: 286, width: 420, height: 24))

let iconRect = NSRect(x: 118, y: 112, width: 164, height: 164)
appIcon.draw(in: iconRect)

let applicationsBadgeRect = NSRect(x: 610, y: 110, width: 168, height: 168)
let badgePath = NSBezierPath(roundedRect: applicationsBadgeRect, xRadius: 38, yRadius: 38)
NSColor(calibratedWhite: 1.0, alpha: 0.08).setFill()
badgePath.fill()
NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
badgePath.lineWidth = 1
badgePath.stroke()

let badgeInset = applicationsBadgeRect.insetBy(dx: 44, dy: 44)
let folderPath = NSBezierPath(roundedRect: badgeInset, xRadius: 16, yRadius: 16)
NSColor(calibratedRed: 110.0 / 255.0, green: 194.0 / 255.0, blue: 1.0, alpha: 0.95).setFill()
folderPath.fill()

let tabRect = NSRect(x: badgeInset.minX + 12, y: badgeInset.maxY - 20, width: 48, height: 18)
let tabPath = NSBezierPath(roundedRect: tabRect, xRadius: 8, yRadius: 8)
NSColor(calibratedRed: 164.0 / 255.0, green: 220.0 / 255.0, blue: 1.0, alpha: 0.95).setFill()
tabPath.fill()

NSAttributedString(
    string: "Applications",
    attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.98, alpha: 0.95),
    ]
).draw(in: NSRect(x: applicationsBadgeRect.minX + 20, y: applicationsBadgeRect.minY + 22, width: 128, height: 28))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 326, y: 190))
arrow.curve(to: NSPoint(x: 580, y: 190), controlPoint1: NSPoint(x: 400, y: 250), controlPoint2: NSPoint(x: 500, y: 130))
arrow.lineWidth = 12
arrow.lineCapStyle = .round

let arrowGradient = NSGradient(colors: [
    NSColor(calibratedRed: 142.0 / 255.0, green: 249.0 / 255.0, blue: 1.0, alpha: 0.95),
    NSColor(calibratedRed: 253.0 / 255.0, green: 224.0 / 255.0, blue: 71.0 / 255.0, alpha: 0.95),
    NSColor(calibratedRed: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0, alpha: 0.95),
])!
arrowGradient.draw(in: arrow, angle: 0)

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 560, y: 224))
arrowHead.line(to: NSPoint(x: 608, y: 190))
arrowHead.line(to: NSPoint(x: 560, y: 156))
arrowHead.lineWidth = 12
arrowHead.lineCapStyle = .round
arrowGradient.draw(in: arrowHead, angle: 0)

NSAttributedString(
    string: "Drag & Drop",
    attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.92),
    ]
).draw(at: NSPoint(x: 364, y: 235))

let footnote = NSBezierPath(roundedRect: NSRect(x: 80, y: 68, width: 338, height: 34), xRadius: 17, yRadius: 17)
NSColor(calibratedWhite: 1.0, alpha: 0.06).setFill()
footnote.fill()

NSAttributedString(
    string: "README im DMG: Features, Setup und Voraussetzungen.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 0.82),
        .paragraphStyle: wrappedParagraph,
    ]
).draw(in: NSRect(x: 96, y: 74, width: 306, height: 28))

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("failed to encode png\n", stderr)
    exit(1)
}

try pngData.write(to: outputURL)
