import AppKit
import CoreGraphics

struct Display: Identifiable, Equatable {
    let id: String
    let name: String
}

struct DisplaySnapshot {
    let source: Int?
    let external: [Display]
    let sleeping: Bool
}

enum Hardware {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    static let getBrightness: GetBrightness? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    @MainActor static func snapshot() -> DisplaySnapshot {
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen)
        }
        var source: Int?
        if let (id, _) = screens.first(where: { CGDisplayIsBuiltin($0.0) != 0 }),
           CGDisplayIsAsleep(id) == 0, CGDisplayIsActive(id) != 0 {
            var brightness: Float = 0
            if getBrightness?(id, &brightness) == 0, brightness.isFinite, (0...1).contains(brightness) {
                source = Int((brightness * 100).rounded())
            }
        }
        let external = screens.compactMap { id, screen -> Display? in
            guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsAsleep(id) == 0,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid) else { return nil }
            return Display(id: string as String, name: screen.localizedName)
        }
        return DisplaySnapshot(source: source, external: external,
                               sleeping: screens.isEmpty || screens.allSatisfy { CGDisplayIsAsleep($0.0) != 0 })
    }
}

struct Backlight: Equatable {
    let raw: Int
    let max: Int
    var percent: Int { Int((Double(raw) * 100 / Double(max)).rounded()) }
    func rawValue(for percent: Int) -> Int { Int((Double(percent) * Double(max) / 100).rounded()) }
}

actor DDC {
    private let helper: URL
    init(helper: URL) { self.helper = helper }

    func read(_ id: String, max knownMax: Int? = nil) -> Backlight? {
        guard let max = knownMax ?? number(id, "max"), max > 0,
              let raw = number(id, "get"), (0...max).contains(raw) else { return nil }
        return Backlight(raw: raw, max: max)
    }

    func write(_ id: String, raw: Int, max: Int) -> Backlight? {
        guard let result = run(id, ["set", "luminance", String(raw)]),
              result == "Writing \(raw)" else { return nil }
        return read(id, max: max)
    }

    private func number(_ id: String, _ operation: String) -> Int? {
        run(id, [operation, "luminance"]).flatMap(Int.init)
    }

    private func run(_ id: String, _ args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = ["display", id] + args
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.012)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
