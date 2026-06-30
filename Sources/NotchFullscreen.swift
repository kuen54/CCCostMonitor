import AppKit

// MARK: - SkyLight private-API helpers (graceful, runtime-resolved)
//
// The two private-framework wrappers behind the notch's "float over fullscreen"
// behavior, isolated here so the most fragile part of the notch code (dlopen/dlsym
// into SkyLight) is one auditable unit. Both resolve every symbol at RUNTIME and
// degrade to a silent no-op / "not fullscreen" if a symbol is missing on a future
// macOS — they never crash. macOS 13 safe (no macOS-14 APIs; yabai / AeroSpace /
// boring.notch use these across 13–15). Used only via their `.shared` singletons
// from NotchController; the panel's enableFullscreenFloat()/disableFullscreenFloat()
// (an NSWindow extension) live next to the panel in NotchController.swift.

// MARK: - FullscreenSpace

/// Moves a panel into a dedicated always-on-top SkyLight "space" so it floats over
/// native-fullscreen apps (`.fullScreenAuxiliary` alone is unreliable there). Symbols are
/// resolved with dlopen/dlsym at RUNTIME; if any are missing on a future macOS,
/// `isAvailable == false` and every method is a silent no-op (never crashes — falls back
/// to the collectionBehavior). Mirrors boring.notch's SkyLight path. Combined with the
/// controller's per-display alpha gating, "float over fullscreen" becomes "reveal with
/// the menu bar in fullscreen".
final class FullscreenSpace {
    static let shared = FullscreenSpace()

    private typealias F_MainConn = @convention(c) () -> Int32
    private typealias F_SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_AddRemove = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias F_RemoveFrom = @convention(c) (Int32, CFArray, CFArray) -> Int32

    let isAvailable: Bool
    private let connection: Int32
    private let space: Int32
    private let addRemove: F_AddRemove?
    private let removeFrom: F_RemoveFrom?
    private static let absoluteLevel: Int32 = Int32.max

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW) else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn = sym("SLSMainConnectionID", F_MainConn.self),
              let create = sym("SLSSpaceCreate", F_SpaceCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", F_SetLevel.self),
              let show = sym("SLSShowSpaces", F_ShowSpaces.self),
              let addRem = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", F_AddRemove.self),
              let remFrom = sym("SLSRemoveWindowsFromSpaces", F_RemoveFrom.self)
        else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        let conn = mainConn()
        let sid = create(conn, 1, 0)
        _ = setLevel(conn, sid, FullscreenSpace.absoluteLevel)
        _ = show(conn, [sid] as CFArray)
        connection = conn; space = sid; addRemove = addRem; removeFrom = remFrom; isAvailable = true
    }

    func add(_ window: NSWindow) {
        guard isAvailable, let addRemove = addRemove else { return }
        _ = addRemove(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func remove(_ window: NSWindow) {
        guard isAvailable, let removeFrom = removeFrom else { return }
        _ = removeFrom(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}

// MARK: - FullscreenDetector

/// Per-display native-fullscreen detector via the private SkyLight space database (the
/// same dylib FullscreenSpace uses). `SLSCopyManagedDisplaySpaces` returns one dictionary
/// PER display; a display's active space is "fullscreen" iff that space carries a
/// `TileLayoutManager` sub-dict — boring.notch / MacroVisionKit's ground-truth test, more
/// robust than the ambiguous CGSSpaceType enum (standalone enum says 1, the managed-
/// display dict's "type" says 4). Symbols are dlsym'd at RUNTIME; if any are missing on a
/// future macOS, `isAvailable == false` and `isFullscreen` returns false — i.e. degrade
/// to "treat as not fullscreen" (the pill keeps floating) rather than crash. macOS 13
/// safe (no macOS-14 APIs; yabai/AeroSpace/boring.notch use these across 13–15).
final class FullscreenDetector {
    static let shared = FullscreenDetector()

    private typealias F_MainConn = @convention(c) () -> Int32
    private typealias F_CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    let isAvailable: Bool
    private let connection: Int32
    private let copySpaces: F_CopySpaces?

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW) else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn = sym("SLSMainConnectionID", F_MainConn.self),
              let copy = sym("SLSCopyManagedDisplaySpaces", F_CopySpaces.self)
                      ?? sym("CGSCopyManagedDisplaySpaces", F_CopySpaces.self)
        else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        connection = mainConn()
        copySpaces = copy
        isAvailable = true
    }

    /// True iff the display with this UUID currently shows a native-fullscreen space.
    /// Degrades to false if the SkyLight query is unavailable or the display isn't found
    /// (e.g. "Displays have separate Spaces" off collapses the enumeration).
    func isFullscreen(displayUUID: String) -> Bool {
        guard isAvailable, let copySpaces = copySpaces,
              let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return false }

        for display in displays {
            guard display["Display Identifier"] as? String == displayUUID else { continue }
            guard let current = display["Current Space"] as? [String: Any],
                  let activeID = current["ManagedSpaceID"] as? Int,
                  let spaces = display["Spaces"] as? [[String: Any]]
            else { return false }
            for space in spaces where (space["ManagedSpaceID"] as? Int) == activeID {
                return space["TileLayoutManager"] != nil
            }
            return false
        }
        return false
    }
}
