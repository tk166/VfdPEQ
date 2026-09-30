import AppKit
// SVG → PNG (alpha 保留)：macOS 原生 NSImage 渲染（支持 filter/渐变）
// 用法: svg2png <input.svg> <output.png> <size>
let args = CommandLine.arguments
guard args.count >= 4, let size = Int(args[3]) else {
    FileHandle.standardError.write("usage: svg2png <in.svg> <out.png> <size>\n".data(using: .utf8)!)
    exit(1)
}
guard let img = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("cannot load SVG\n".data(using: .utf8)!)
    exit(2)
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: NSColorSpaceName.deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(3) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// SVG 的 viewBox 居中绘制（保持宽高比）
let svgSize = img.size
let scale = min(Double(size)/svgSize.width, Double(size)/svgSize.height)
let w = svgSize.width*scale, h = svgSize.height*scale
img.draw(in: NSRect(x: (Double(size)-w)/2, y: (Double(size)-h)/2, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
try! png.write(to: URL(fileURLWithPath: args[2]))
