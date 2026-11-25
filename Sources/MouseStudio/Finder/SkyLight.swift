import CoreGraphics
import Darwin

/// Window-server calls that have no public equivalent. They are looked up at run time, so if a macOS update removes
/// one, that part quietly falls back (or is skipped) instead of the app failing to start. Each fallback is noted in
/// `FinderLog`, which "Copy Recent Mouse Events" includes.
enum SkyLight {
    typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: type) }
    }

    static let setFront = symbol("_SLPSSetFrontProcessWithOptions", as: SetFront.self)
    static let postEvent = symbol("SLPSPostEventRecordTo", as: PostEvent.self)
    static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    static let copyDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self)
    static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)

    /// Names of the calls that are missing on this Mac.
    static var missing: [String] {
        var names: [String] = []
        if setFront == nil { names.append("SLPSSetFrontProcessWithOptions") }
        if postEvent == nil { names.append("SLPSPostEventRecordTo") }
        if mainConnection == nil { names.append("CGSMainConnectionID") }
        if copyDisplaySpaces == nil { names.append("CGSCopyManagedDisplaySpaces") }
        if copySpacesForWindows == nil { names.append("CGSCopySpacesForWindows") }
        return names
    }
}
