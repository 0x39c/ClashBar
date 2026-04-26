import AppKit

@MainActor
enum BrandIcon {
    private static let logoRelativePaths = [
        "Assets.xcassets/BrandLogo.imageset/logo.png",
        "Resources/Assets.xcassets/BrandLogo.imageset/logo.png",
    ]
    private static let runProxyRelativePaths = [
        "Assets.xcassets/BrandRunProxy.imageset/icon-run-proxy.png",
        "Resources/Assets.xcassets/BrandRunProxy.imageset/icon-run-proxy.png",
    ]
    private static let sleepRelativePaths = [
        "Assets.xcassets/BrandSleep.imageset/icon-sleep.png",
        "Resources/Assets.xcassets/BrandSleep.imageset/icon-sleep.png",
    ]
    private static let runGlobalRelativePaths = [
        "Assets.xcassets/BrandRunGlobal.imageset/icon-run-global.png",
        "Resources/Assets.xcassets/BrandRunGlobal.imageset/icon-run-global.png",
    ]
    private static let runDirectRelativePaths = [
        "Assets.xcassets/BrandRunDirect.imageset/icon-run-direct.png",
        "Resources/Assets.xcassets/BrandRunDirect.imageset/icon-run-direct.png",
    ]

    static let image: NSImage? = loadImage(relativePaths: logoRelativePaths)
    static let runProxyImage: NSImage? = loadImage(relativePaths: runProxyRelativePaths)
    static let sleepImage: NSImage? = loadImage(relativePaths: sleepRelativePaths)
    static let runGlobalImage: NSImage? = loadImage(relativePaths: runGlobalRelativePaths)
    static let runDirectImage: NSImage? = loadImage(relativePaths: runDirectRelativePaths)

    private static func loadImage(relativePaths: [String]) -> NSImage? {
        for bundle in AppResourceBundleLocator.candidateBundles() {
            for relativePath in relativePaths {
                let url = bundle.bundleURL.appendingPathComponent(relativePath, isDirectory: false)
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }
        return nil
    }
}
