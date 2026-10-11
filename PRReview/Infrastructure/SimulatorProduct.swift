import Foundation

/// Resolve the built app from Xcode metadata rather than choosing an arbitrary .app.
enum SimulatorProduct {
    static func resolve(_ output: String, derivedData: URL) throws -> SimulatorApp {
        struct Target: Decodable { let buildSettings: [String: String] }
        let targets = try JSONDecoder().decode([Target].self, from: Data(output.utf8))
        let apps = targets.map(\.buildSettings).filter {
            $0["PRODUCT_TYPE"] == "com.apple.product-type.application" && $0["PLATFORM_NAME"] == "iphonesimulator"
        }
        guard apps.count == 1, let settings = apps.first,
              let directory = settings["TARGET_BUILD_DIR"], let name = settings["FULL_PRODUCT_NAME"],
              name.hasSuffix(".app"), !name.contains("/"), let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"],
              !bundleID.isEmpty, bundleID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw ReviewError("起動するiOSアプリを1つに特定できません。アプリを1つだけビルドするSchemeを選択してください。")
        }
        let root = derivedData.standardizedFileURL
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name).standardizedFileURL
        let plist = url.appendingPathComponent("Info.plist")
        guard url.path.hasPrefix(root.path + "/"), root.resolvingSymlinksInPath() == root,
              url.resolvingSymlinksInPath() == url, plist.resolvingSymlinksInPath() == plist,
              (try? plist.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ReviewError("専用DerivedData内にビルド済みのアプリが見つかりません。ビルド出力先のカスタム設定を確認してください。")
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              (info?["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneSimulator") == true else {
            throw ReviewError("ビルド済みアプリのBundle IDまたは対応プラットフォームが一致しません。")
        }
        return SimulatorApp(url: url, bundleID: bundleID)
    }
}
