import Foundation
import Testing
@testable import PRReview

@MainActor
struct XcodeBuildIntegrationTests {
    @Test(.timeLimit(.minutes(2)))
    func realXcodeBuildAndTestPersistResultsAndCleanManagedArtifacts() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repositoryRoot = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try SmokeProject.write(to: repositoryRoot)
        _ = try await CommandRunner.git(repositoryRoot.path, ["init", "--quiet"])
        _ = try await CommandRunner.git(repositoryRoot.path, ["add", "."])
        _ = try await CommandRunner.git(repositoryRoot.path, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"])
        let sha = try await CommandRunner.git(repositoryRoot.path, ["rev-parse", "HEAD"])
        let service = ReviewService(storage: directory.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: service.worktrees, withIntermediateDirectories: true)
        let sessionID = UUID()
        let path = service.worktrees.appendingPathComponent(sessionID.uuidString).path
        _ = try await CommandRunner.git(repositoryRoot.path, ["worktree", "add", "--detach", path, sha])
        let repository = Repository(path: repositoryRoot.path, slug: "fixture/smoke", entry: "Smoke.xcodeproj")
        let session = Session(id: sessionID, repository: repository, prURL: "https://github.com/fixture/smoke/pull/1", number: 1, title: "Local Xcode fixture", sha: sha, path: path)
        var initial = SavedState(); initial.repositories = [repository]; initial.sessions = [session]
        try service.stateStore.save(initial)
        let coordinator = ReviewCoordinator(service: service)
        let builds = XcodeBuildService(storage: service.storage)
        let schemes = try await builds.schemes(session)
        #expect(schemes.contains("Smoke"))
        let destinations = try await builds.destinations(session, scheme: "Smoke")
        let destination = try #require(destinations.first { $0.platform == "macOS" })
        let settings = BuildSettings(scheme: "Smoke", destination: destination)
        try coordinator.saveBuildSettings(settings, for: session)
        for action in [BuildAction.build, .test] {
            let record = try await coordinator.runBuild(session, settings: settings, action: action)
            let log = try String(contentsOfFile: record.logPath, encoding: .utf8)
            #expect(record.status == .succeeded, "\(action.rawValue) failed:\n\(log.suffix(10000))")
            #expect(record.sha == sha)
            #expect(!record.sourceModified)
            #expect(record.resultPath != nil)
            #expect(!log.isEmpty)
        }
        let reloaded = try service.stateStore.load()
        #expect(reloaded.sessions.first?.buildRecords?.map(\.action) == [.build, .test])
        #expect(reloaded.sessions.first?.repository.buildSettings == settings)
        #expect(FileManager.default.fileExists(atPath: try builds.artifacts(for: sessionID).appendingPathComponent("DerivedData").path))
        #expect(try await service.inspect(session).isEmpty)
        try await coordinator.remove(session)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: try builds.artifacts(for: sessionID).path))
        #expect(try service.stateStore.load().sessions.isEmpty)
        #expect(try String(contentsOf: repositoryRoot.appendingPathComponent("main.swift"), encoding: .utf8) == SmokeProject.toolSource)
        #expect(try await CommandRunner.git(repositoryRoot.path, ["status", "--porcelain"]).isEmpty)
    }
}

/// A small real Xcode project with no packages, signing account, or application host.
private enum SmokeProject {
    static let toolSource = "print(\"Review smoke fixture\")\n"

    static func write(to root: URL) throws {
        var objects: [String: [String: Any]] = [:]
        var counter = 0
        func object(_ values: [String: Any]) -> String {
            counter += 1
            let identifier = String(format: "%024X", counter)
            objects[identifier] = values
            return identifier
        }
        func configurations(_ extra: [String: Any] = [:]) -> String {
            var settings: [String: Any] = [
                "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "26.0", "SWIFT_VERSION": "6.0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "ONLY_ACTIVE_ARCH": "YES",
                "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "PRODUCT_NAME": "$(TARGET_NAME)"
            ]
            settings.merge(extra) { _, new in new }
            let debug = object(["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": settings])
            return object(["isa": "XCConfigurationList", "buildConfigurations": [debug], "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Debug"])
        }
        func sourcePhase(_ file: String) -> String {
            let reference = object(["isa": "PBXFileReference", "path": file, "sourceTree": "SOURCE_ROOT", "lastKnownFileType": "sourcecode.swift"])
            let buildFile = object(["isa": "PBXBuildFile", "fileRef": reference])
            return object(["isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647", "files": [buildFile], "runOnlyForDeploymentPostprocessing": "0"])
        }
        let tool = object(["isa": "PBXFileReference", "path": "SmokeTool", "sourceTree": "BUILT_PRODUCTS_DIR", "explicitFileType": "compiled.mach-o.executable"])
        let tests = object(["isa": "PBXFileReference", "path": "SmokeTests.xctest", "sourceTree": "BUILT_PRODUCTS_DIR", "explicitFileType": "wrapper.cfbundle"])
        let products = object(["isa": "PBXGroup", "name": "Products", "children": [tool, tests], "sourceTree": "<group>"])
        let mainGroup = object(["isa": "PBXGroup", "children": [products], "sourceTree": "<group>"])
        let toolTarget = object([
            "isa": "PBXNativeTarget", "name": "SmokeTool", "productName": "SmokeTool", "productReference": tool,
            "productType": "com.apple.product-type.tool", "buildConfigurationList": configurations(),
            "buildPhases": [sourcePhase("main.swift")], "buildRules": [], "dependencies": []
        ])
        let testTarget = object([
            "isa": "PBXNativeTarget", "name": "SmokeTests", "productName": "SmokeTests", "productReference": tests,
            "productType": "com.apple.product-type.bundle.unit-test",
            "buildConfigurationList": configurations(["GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "dev.fixture.smoke.tests"]),
            "buildPhases": [sourcePhase("SmokeTests.swift")], "buildRules": [], "dependencies": []
        ])
        let project = object([
            "isa": "PBXProject", "compatibilityVersion": "Xcode 14.0", "mainGroup": mainGroup, "productRefGroup": products,
            "buildConfigurationList": configurations(), "targets": [toolTarget, testTarget],
            "developmentRegion": "en", "knownRegions": ["en"], "projectDirPath": "", "projectRoot": "", "attributes": [:]
        ])
        let projectRoot = root.appendingPathComponent("Smoke.xcodeproj")
        let schemeRoot = projectRoot.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemeRoot, withIntermediateDirectories: true)
        let workspace = projectRoot.appendingPathComponent("project.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Workspace version=\"1.0\"><FileRef location=\"self:\"/></Workspace>\n".utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        let plist: [String: Any] = ["archiveVersion": "1", "objectVersion": "56", "classes": [:], "objects": objects, "rootObject": project]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: projectRoot.appendingPathComponent("project.pbxproj"))
        func reference(_ id: String, name: String, product: String) -> String {
            "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(id)\" BuildableName=\"\(product)\" BlueprintName=\"\(name)\" ReferencedContainer=\"container:Smoke.xcodeproj\"/>"
        }
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.3">
        <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
        <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">\(reference(toolTarget, name: "SmokeTool", product: "SmokeTool"))</BuildActionEntry>
        </BuildActionEntries></BuildAction>
        <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO">\(reference(testTarget, name: "SmokeTests", product: "SmokeTests.xctest"))</TestableReference></Testables></TestAction>
        <LaunchAction buildConfiguration="Debug"/><AnalyzeAction buildConfiguration="Debug"/>
        </Scheme>
        """
        try Data(scheme.utf8).write(to: schemeRoot.appendingPathComponent("Smoke.xcscheme"))
        try Data(toolSource.utf8).write(to: root.appendingPathComponent("main.swift"))
        let testSource = "import XCTest\nfinal class SmokeTests: XCTestCase { func testFixture() { XCTAssertEqual(2 + 2, 4) } }\n"
        try Data(testSource.utf8).write(to: root.appendingPathComponent("SmokeTests.swift"))
        try Data("xcuserdata/\n*.xcuserstate\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    }
}
