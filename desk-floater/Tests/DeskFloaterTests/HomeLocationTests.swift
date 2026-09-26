import XCTest
@testable import DeskFloater

final class HomeLocationTests: XCTestCase {
    private let bundle = "/Users/me/starship/desk-floater/.build/DeskFloater.app"
    private let roots: Set<String> = ["/Users/me/starship", "/Users/me/other"]

    private func resolve(
        _ environment: [String: String],
        bundle: String? = nil,
        cwd: String = "/"
    ) -> (root: String, home: String)? {
        HomeLocation.resolve(
            environment: environment,
            bundlePath: bundle ?? self.bundle,
            currentDirectory: cwd,
            isCodeRoot: { self.roots.contains($0) }
        )
    }

    func testLauncherEnvironmentWins() {
        let location = resolve(["FM_DESK_FLOATER_ROOT": "/Users/me/other", "FM_HOME": "/Users/me/home"])
        XCTAssertEqual(location?.root, "/Users/me/other")
        XCTAssertEqual(location?.home, "/Users/me/home")
    }

    func testReopenWithoutEnvironmentFindsRootFromBundle() {
        let location = resolve([:])
        XCTAssertEqual(location?.root, "/Users/me/starship")
        XCTAssertEqual(location?.home, "/Users/me/starship", "the home defaults to the code root")
    }

    func testEmptyEnvironmentValuesCountAsUnset() {
        let location = resolve(["FM_DESK_FLOATER_ROOT": "", "FM_HOME": ""])
        XCTAssertEqual(location?.root, "/Users/me/starship")
        XCTAssertEqual(location?.home, "/Users/me/starship")
    }

    func testNeverFallsBackToSlash() {
        XCTAssertNil(resolve([:], bundle: "/Applications/DeskFloater.app"))
        XCTAssertNil(resolve([:], bundle: "/tmp/elsewhere/desk-floater/.build/DeskFloater.app"),
                     "a bundle outside a Firstmate code root is not trusted")
    }

    func testWorkingDirectoryCountsOnlyWhenItIsACodeRoot() {
        let location = resolve([:], bundle: "/tmp/x/DeskFloater", cwd: "/Users/me/other")
        XCTAssertEqual(location?.root, "/Users/me/other")
        XCTAssertEqual(location?.home, "/Users/me/other")
        XCTAssertNil(resolve([:], bundle: "/tmp/x/DeskFloater", cwd: "/Users/me/nowhere"),
                     "a working directory that is not a code root is not trusted")
    }
}
