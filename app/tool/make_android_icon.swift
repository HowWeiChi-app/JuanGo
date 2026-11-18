// 產生 Android 圖示：iOS 版的鳳凰圖（白色）放在 iOS 圖示的深紅底上。
// adaptive icon 的圖層是 108dp、桌面只露出中間約 72dp，所以鳳凰放在中間 2/3。
// 用法（在 app 資料夾）：
//   swiftc -O tool/make_android_icon.swift -o /tmp/make-android-icon
//   /tmp/make-android-icon ../ios/JuanGo/AppIcon.icon/Assets/phoenix.png tool/icon
import AppKit

let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = args[2]
let red = CGColor(srgbRed: 0.59009, green: 0.05846, blue: 0.14712, alpha: 1)

func render(_ size: Int, to path: String, draw: (CGContext, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    c.interpolationQuality = .high
    draw(c, CGFloat(size))
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// 鳳凰圖只取形狀（透明度），一律塗成白色
func phoenix(_ c: CGContext, in r: CGRect) {
    c.saveGState()
    c.clip(to: r, mask: source)
    c.setFillColor(.white)
    c.fill(r)
    c.restoreGState()
}

for (name, dp) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
    let dir = "\(out)/mipmap-\(name)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    render(Int(108 * dp), to: "\(dir)/ic_launcher_foreground.png") { c, n in
        c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        phoenix(c, in: CGRect(x: n / 6, y: n / 6, width: n * 2 / 3, height: n * 2 / 3))
    }
    render(Int(48 * dp), to: "\(dir)/ic_launcher.png") { c, n in
        c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        phoenix(c, in: CGRect(x: 0, y: 0, width: n, height: n))
    }
}
// 通知列的小圖示：Android 只看透明度，所以是透明底的白色鳳凰
for (name, dp) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
    render(Int(24 * dp), to: "\(out)/mipmap-\(name)/ic_notification.png") { c, n in
        phoenix(c, in: CGRect(x: 0, y: 0, width: n, height: n))
    }
}
let any = "\(out)/mipmap-anydpi-v26"
try! FileManager.default.createDirectory(atPath: any, withIntermediateDirectories: true)
try! """
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@android:color/black" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>

""".write(toFile: "\(any)/ic_launcher.xml", atomically: true, encoding: .utf8)
