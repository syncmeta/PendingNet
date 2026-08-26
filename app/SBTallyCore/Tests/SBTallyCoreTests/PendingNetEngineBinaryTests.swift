import XCTest
@testable import SBTallyCore

final class PendingNetEngineBinaryTests: XCTestCase {
    private let macOS = URL(fileURLWithPath: "/Applications/PendingNet.app/Contents/MacOS")

    /// 包内那份必须排在 homebrew / usr-local 前面。反过来的话，开发机上装过
    /// sing-box 的人永远跑的是机器上那份，包里编进去的引擎一次都不会被用到 ——
    /// 而且这种错法在我们自己的机器上完全看不出来。
    func testBundledEngineOutranksTheMachineOne() {
        let candidates = PendingNetEngineBinary.candidatePaths(siblingDirectories: [macOS])
        XCTAssertEqual(candidates.first, "/Applications/PendingNet.app/Contents/MacOS/sing-box")
        XCTAssertEqual(
            Array(candidates.dropFirst()),
            ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        )
    }

    func testPicksTheBundledEngineWhenBothExist() {
        let found = PendingNetEngineBinary.locate(
            siblingDirectories: [macOS],
            isExecutable: { _ in true }
        )
        XCTAssertEqual(found, "/Applications/PendingNet.app/Contents/MacOS/sing-box")
    }

    /// 包里没有就退回机器上那份 —— 开发机上手边有什么就用什么，仍然管用。
    func testFallsBackToTheMachineEngine() {
        let found = PendingNetEngineBinary.locate(
            siblingDirectories: [macOS],
            isExecutable: { $0 == "/usr/local/bin/sing-box" }
        )
        XCTAssertEqual(found, "/usr/local/bin/sing-box")
    }

    func testReportsNothingWhenNoCandidateIsExecutable() {
        XCTAssertNil(PendingNetEngineBinary.locate(
            siblingDirectories: [macOS],
            isExecutable: { _ in false }
        ))
    }

    /// 助手由 launchd 按 `BundleProgram` 拉起，`Bundle.main` 可能给不出
    /// executableURL；argv[0] 那条必须还在，否则 TUN / 系统代理下引擎就找不着了。
    func testArgv0CarriesTheHelperWhenTheBundleCannot() {
        let directories = PendingNetEngineBinary.siblingDirectories(
            bundleExecutable: nil,
            argv0: "/Applications/PendingNet.app/Contents/MacOS/PendingNetHelper"
        )
        XCTAssertEqual(directories.map(\.path), [macOS.path])
    }

    /// 两条路指向同一个目录时只留一条 —— 否则候选表里出现重复项，
    /// 排错时看到的路径清单会莫名其妙地把同一个位置写两遍。
    func testDeduplicatesTheSameDirectory() {
        let directories = PendingNetEngineBinary.siblingDirectories(
            bundleExecutable: macOS.appendingPathComponent("PendingNet"),
            argv0: "/Applications/PendingNet.app/Contents/MacOS/PendingNet"
        )
        XCTAssertEqual(directories.map(\.path), [macOS.path])
    }

    func testKeepsBothDirectoriesWhenTheyDiffer() {
        let directories = PendingNetEngineBinary.siblingDirectories(
            bundleExecutable: URL(fileURLWithPath: "/one/PendingNet"),
            argv0: "/two/PendingNet"
        )
        XCTAssertEqual(directories.map(\.path), ["/one", "/two"])
    }

    /// 「请先安装 sing-box」是内置之后的误导文案：用户装一个也修不好。
    func testMissingEngineTextDoesNotTellTheUserToInstallSingBox() {
        XCTAssertFalse(PendingNetEngineBinary.missingEngineMessage.contains("请先安装"))
        XCTAssertTrue(PendingNetEngineBinary.missingEngineMessage.contains("重新下载"))
    }
}
