import AppKit

/// Captured before NSApplication is created, so the stub process can report its
/// real cold-launch-to-panel latency.
let appLaunchTime = CFAbsoluteTimeGetCurrent()

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
