import AppKit
import Foundation

// Build-time helper: regenerates Resources/AppIcon.icns from IconRenderer,
// so the shipped app icon and the generated group icons share one style.
let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: IconGen <output.icns>\n".utf8))
    exit(1)
}
let dest = URL(fileURLWithPath: args[1])
IconRenderer.writeICNS(IconRenderer.appImage(), to: dest)
print("Generated \(dest.path)")
