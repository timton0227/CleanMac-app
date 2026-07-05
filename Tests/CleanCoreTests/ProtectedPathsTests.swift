import Foundation
import Testing
@testable import CleanCore

/// FR-SAFE-1 + FR-BUNDLE acceptance: every protected path is refused; files
/// inside packages are refused; ordinary paths are allowed.
struct ProtectedPathsTests {
    let pp = ProtectedPaths()

    @Test("SIP and system-critical locations are refused")
    func systemLocationsRefused() {
        let refused = [
            "/System/Library/Caches/foo",
            "/usr/lib/whatever",
            "/bin/ls",
            "/sbin/launchd",
            "/Library/Apple/System/x",
            "/",
            "/Users",
            "/System",
        ]
        for path in refused {
            #expect(pp.verdict(for: URL(fileURLWithPath: path)).isProtected,
                    "expected refusal for \(path)")
        }
    }

    @Test("Carved-out exceptions and ordinary user paths are allowed")
    func allowedPaths() {
        let allowed = [
            "/usr/local/bin/tool",
            NSHomeDirectory() + "/Library/Caches/com.example.app",
            NSHomeDirectory() + "/Downloads/big.dmg",
        ]
        for path in allowed {
            #expect(!pp.verdict(for: URL(fileURLWithPath: path)).isProtected,
                    "expected allowed for \(path)")
        }
    }

    @Test("Home directory root itself is refused")
    func homeRootRefused() {
        #expect(pp.verdict(for: FileManager.default.homeDirectoryForCurrentUser).isProtected)
    }

    @Test("A file inside a package/bundle is refused (FR-BUNDLE)")
    func insidePackageRefused() {
        let inside = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Pictures/Photos Library.photoslibrary/originals/1/IMG.jpg")
        #expect(pp.verdict(for: inside).isProtected)

        let appInternal = URL(fileURLWithPath: "/Applications/Some.app/Contents/MacOS/Some")
        #expect(pp.verdict(for: appInternal).isProtected)
    }

    @Test("Prefix matching is boundary-aware (/usr does not match /usration)")
    func boundaryAware() {
        #expect(!pp.verdict(for: URL(fileURLWithPath: NSHomeDirectory() + "/usration")).isProtected)
    }
}
