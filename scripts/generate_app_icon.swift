import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "macos/Runner/Assets.xcassets/AppIcon.appiconset")

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawIcon(size: Int) throws {
  let canvas = CGFloat(size)
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: size,
      pixelsHigh: size,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else {
    throw NSError(domain: "XplainRIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create bitmap rep"])
  }

  rep.size = NSSize(width: canvas, height: canvas)

  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current = context

  let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
  NSColor.clear.setFill()
  rect.fill()

  let inset = canvas * 0.045
  let iconRect = rect.insetBy(dx: inset, dy: inset)
  let cornerRadius = canvas * 0.215
  let iconShape = NSBezierPath(
    roundedRect: iconRect,
    xRadius: cornerRadius,
    yRadius: cornerRadius
  )

  iconShape.addClip()

  let background = NSGradient(colors: [
    color(18, 8, 41),
    color(47, 15, 85),
    color(72, 23, 125),
  ])!
  background.draw(in: iconShape, angle: 135)

  color(117, 72, 190, 0.26).setFill()
  NSBezierPath(
    ovalIn: NSRect(
      x: canvas * 0.47,
      y: canvas * 0.47,
      width: canvas * 0.52,
      height: canvas * 0.52
    )
  ).fill()

  color(0, 200, 255, 0.13).setFill()
  NSBezierPath(
    ovalIn: NSRect(
      x: -canvas * 0.12,
      y: -canvas * 0.10,
      width: canvas * 0.58,
      height: canvas * 0.58
    )
  ).fill()

  iconShape.lineWidth = max(1, canvas * 0.014)
  color(184, 151, 255, 0.26).setStroke()
  iconShape.stroke()

  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center

  let shadow = NSShadow()
  shadow.shadowColor = color(0, 0, 0, 0.38)
  shadow.shadowBlurRadius = max(2, canvas * 0.028)
  shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.018)

  let font = NSFont.systemFont(ofSize: canvas * 0.39, weight: .black)
  let text = "XR" as NSString
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color(129, 231, 255),
    .paragraphStyle: paragraph,
    .kern: -canvas * 0.012,
    .shadow: shadow,
  ]

  let textSize = text.size(withAttributes: attributes)
  let textRect = NSRect(
    x: (canvas - textSize.width) / 2,
    y: (canvas - textSize.height) / 2 + canvas * 0.012,
    width: textSize.width,
    height: textSize.height
  )
  text.draw(in: textRect, withAttributes: attributes)

  NSGraphicsContext.restoreGraphicsState()

  guard let png = rep.representation(using: .png, properties: [:]) else {
    throw NSError(domain: "XplainRIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
  }

  let fileURL = outputDirectory.appendingPathComponent("app_icon_\(size).png")
  try png.write(to: fileURL)
}

try FileManager.default.createDirectory(
  at: outputDirectory,
  withIntermediateDirectories: true
)

for size in sizes {
  try drawIcon(size: size)
}
