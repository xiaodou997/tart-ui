#!/usr/bin/env swift

// 生成应用图标。
//
// 输出 1024×1024 的 PNG，再由 bundle.sh 转成 .icns。
// 遵循 macOS Big Sur 之后的图标规范：圆角矩形底板，图形留出四周边距。

import AppKit
import Foundation

let canvasSize = 1024.0
// Big Sur 风格：图形占画布约 80%，四周留白。
let inset = canvasSize * 0.1
let plateRect = NSRect(
  x: inset, y: inset,
  width: canvasSize - inset * 2,
  height: canvasSize - inset * 2
)
// 圆角半径约为底板边长的 22.37%，这是 Apple 的比例。
let cornerRadius = plateRect.width * 0.2237

let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
  fatalError("无法获取绘图上下文")
}

// 底板渐变：偏冷的蓝紫，和虚拟化/系统工具的气质接近。
let plate = NSBezierPath(roundedRect: plateRect, xRadius: cornerRadius, yRadius: cornerRadius)
plate.addClip()

let gradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.90, alpha: 1.0),
  NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.68, alpha: 1.0),
])!
gradient.draw(in: plateRect, angle: -90)

// 顶部一层柔和高光，避免纯平色显得死板。
let highlight = NSGradient(colors: [
  NSColor(white: 1.0, alpha: 0.22),
  NSColor(white: 1.0, alpha: 0.0),
])!
highlight.draw(in: NSRect(
  x: plateRect.minX, y: plateRect.midY,
  width: plateRect.width, height: plateRect.height / 2
), angle: -90)

// 画一个显示器轮廓，表示虚拟机。
let screenWidth = plateRect.width * 0.56
let screenHeight = screenWidth * 0.68
let screenRect = NSRect(
  x: plateRect.midX - screenWidth / 2,
  y: plateRect.midY - screenHeight / 2 + plateRect.height * 0.06,
  width: screenWidth,
  height: screenHeight
)

let stroke = plateRect.width * 0.035
NSColor.white.setStroke()
let screen = NSBezierPath(roundedRect: screenRect, xRadius: stroke * 1.6, yRadius: stroke * 1.6)
screen.lineWidth = stroke
screen.stroke()

// 标题栏分隔线，让它更像一个窗口而不是相框。
let titleBarY = screenRect.maxY - screenHeight * 0.22
let separator = NSBezierPath()
separator.move(to: NSPoint(x: screenRect.minX, y: titleBarY))
separator.line(to: NSPoint(x: screenRect.maxX, y: titleBarY))
separator.lineWidth = stroke * 0.7
separator.stroke()

// 标题栏上的三个圆点。
let dotRadius = stroke * 0.62
let dotSpacing = dotRadius * 3.4
let dotY = titleBarY + (screenRect.maxY - titleBarY) / 2
NSColor.white.setFill()
for index in 0..<3 {
  let center = NSPoint(
    x: screenRect.minX + stroke * 2.2 + Double(index) * dotSpacing,
    y: dotY
  )
  NSBezierPath(ovalIn: NSRect(
    x: center.x - dotRadius, y: center.y - dotRadius,
    width: dotRadius * 2, height: dotRadius * 2
  )).fill()
}

// 屏幕中央的播放三角，呼应「运行虚拟机」。
let triangleSize = screenHeight * 0.30
let bodyCenterY = (screenRect.minY + titleBarY) / 2
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: screenRect.midX - triangleSize * 0.42, y: bodyCenterY + triangleSize / 2))
triangle.line(to: NSPoint(x: screenRect.midX - triangleSize * 0.42, y: bodyCenterY - triangleSize / 2))
triangle.line(to: NSPoint(x: screenRect.midX + triangleSize * 0.58, y: bodyCenterY))
triangle.close()
triangle.fill()

// 底座。
let standWidth = screenWidth * 0.34
let standHeight = stroke * 1.5
let stand = NSBezierPath(roundedRect: NSRect(
  x: plateRect.midX - standWidth / 2,
  y: screenRect.minY - standHeight * 2.2,
  width: standWidth,
  height: standHeight
), xRadius: standHeight / 2, yRadius: standHeight / 2)
stand.fill()

image.unlockFocus()

// 导出 PNG。
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
  fatalError("图标编码失败")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成 \(outputPath)")
