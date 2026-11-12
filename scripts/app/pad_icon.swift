import AppKit

// Draws an icon tile inside a larger canvas so the visible tile matches the
// macOS icon grid. Mirrors AppBrand.iconContentFraction in the app.
let args = CommandLine.arguments
guard args.count == 4, let fraction = Double(args[3]), fraction > 0, fraction <= 1 else { exit(2) }
guard let source = NSImage(contentsOfFile: args[1]) else { exit(3) }
let side = Int(source.size.width)
guard side > 0, source.size.width == source.size.height else { exit(4) }
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: side * 4, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(5) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let inset = CGFloat(side) * CGFloat(fraction)
source.draw(in: NSRect(x: (CGFloat(side) - inset) / 2, y: (CGFloat(side) - inset) / 2, width: inset, height: inset))
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(6) }
try data.write(to: URL(fileURLWithPath: args[2]))
