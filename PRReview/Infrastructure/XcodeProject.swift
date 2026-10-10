import Foundation

/// Registration, opening and xcodebuild use the same container validation.
struct XcodeProject: Sendable {
    let url: URL

    init(root: String, relativePath: String) throws {
        let entry = try RepositoryFileSafety.file(root: root, relative: relativePath)
        let marker: String
        switch entry.pathExtension {
        case "xcodeproj": marker = "project.pbxproj"
        case "xcworkspace": marker = "contents.xcworkspacedata"
        default: throw ReviewError(".xcworkspaceまたは.xcodeprojを選んでください。")
        }
        let file = try RepositoryFileSafety.file(root: root, relative: relativePath + "/" + marker)
        guard (try? FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType) == .typeDirectory,
              (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw ReviewError("Xcodeプロジェクトの構成ファイルが見つかりません：\(relativePath)")
        }
        url = entry
    }

    var buildArguments: [String] {
        [url.pathExtension == "xcworkspace" ? "-workspace" : "-project", url.path]
    }
}
