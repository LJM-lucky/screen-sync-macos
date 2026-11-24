import AppKit
import Observation
import ServiceManagement

struct Point: Codable, Identifiable, Equatable {
    let input: Int
    let output: Int
    var id: Int { input }
}

struct BrightnessAdjustment: Codable {
    var offset = 0
    var minimum = 0
    var maximum = 100

    func apply(to target: Int) -> Int {
        min(maximum, max(minimum, target + offset))
    }
}

struct FollowTiming {
    private(set) var source: Int?
    private var changedAt: ContinuousClock.Instant?

    mutating func sample(_ brightness: Int?, at now: ContinuousClock.Instant) {
        guard brightness != source else { return }
        source = brightness
        changedAt = now
    }

    func target(at now: ContinuousClock.Instant, delay: Int) -> Int? {
        guard let source, let changedAt, now - changedAt >= .milliseconds(delay) else { return nil }
        return source
    }
}

struct Profile: Codable {
    var enabled = true
    var baseline: Point?
    var points: [Point] = []
    // Optional so profiles written by previous versions still decode.
    var adjustment: BrightnessAdjustment?

    var curve: [Point] {
        let anchors = points.isEmpty ? baseline.map { [$0] } ?? [] : points
        guard let first = anchors.first, let last = anchors.last else { return [] }
        var result = anchors
        if first.input > 0 {
            result.insert(Point(input: 0, output: max(0, first.output - first.input)), at: 0)
        }
        if last.input < 100 {
            result.append(Point(input: 100, output: min(100, last.output + 100 - last.input)))
        }
        return result
    }

    func target(_ input: Int) -> Int {
        let curve = curve
        guard let upper = curve.firstIndex(where: { $0.input >= input }) else { return input }
        guard upper > 0 else { return curve[upper].output }
        let lo = curve[upper - 1]
        let hi = curve[upper]
        let progress = Double(input - lo.input) / Double(hi.input - lo.input)
        return Int((Double(lo.output) + progress * Double(hi.output - lo.output)).rounded())
    }

    mutating func rememberOffset(at input: Int) -> Point? {
        guard var adjustment, adjustment.offset != 0 else { return nil }
        let point = Point(input: input, output: adjustment.apply(to: target(input)))
        var updated = self
        if updated.points.isEmpty, let baseline { updated.points = [baseline] }
        guard updated.add(point) else { return nil }
        adjustment.offset = 0
        updated.adjustment = adjustment
        self = updated
        return point
    }

    mutating func add(_ point: Point) -> Bool {
        var candidate = points.filter { $0.input != point.input }
        candidate.append(point)
        candidate.sort { $0.input < $1.input }
        guard zip(candidate, candidate.dropFirst()).allSatisfy({ $0.output <= $1.output }) else { return false }
        points = candidate
        return true
    }
}

@MainActor @Observable final class SyncModel {
    enum Link: Equatable {
        case probing, ready(Backlight), failed, mismatch(Backlight)
        var value: Backlight? {
            switch self { case let .ready(value), let .mismatch(value): value; default: nil }
        }
    }

    var source: Int?
    var displays: [Display] = []
    var links: [String: Link] = [:]
    var profiles: [String: Profile]
    var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    private(set) var followDelay: Int
    private(set) var holds: [String: Date]
    var calibrating: String? {
        didSet { if calibrating != oldValue { closeComparison() } }
    }
    private(set) var comparisonVisible = false
    var busy: String?
    var message: String?
    private(set) var learningMessage: [String: String] = [:]
    var loginStatus = SMAppService.mainApp.status
    var loginError: String?
    private let defaults = UserDefaults.standard
    private let ddc = DDC(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/m1ddc"))
    private var retryAfter: [String: Date] = [:]
    private var nextRead: [String: Date] = [:]
    private var loop: Task<Void, Never>?
    private var sampler: Task<Void, Never>?
    private var timing = FollowTiming()
    private var latestSnapshot = DisplaySnapshot(source: nil, external: [], sleeping: true)
    private let comparison = CalibrationComparison()
    private var recheckRequested = false

    init() {
        profiles = UserDefaults.standard.data(forKey: "profiles")
            .flatMap { try? JSONDecoder().decode([String: Profile].self, from: $0) } ?? [:]
        paused = UserDefaults.standard.bool(forKey: "paused")
        followDelay = min(5000, max(0, UserDefaults.standard.integer(forKey: "followDelay")))
        holds = (UserDefaults.standard.dictionary(forKey: "holds") as? [String: Date] ?? [:])
            .filter { $0.value > Date() }
    }

    func start() {
        guard loop == nil else { return }
        if !defaults.bool(forKey: "loginConfigured"), loginStatus != .enabled, loginStatus != .requiresApproval {
            setLogin(true)
        }
        sample()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                self?.sample()
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    func setFollowDelay(_ value: Int) {
        let bounded = min(5000, max(0, value))
        guard bounded != followDelay else { return }
        followDelay = bounded
        defaults.set(followDelay, forKey: "followDelay")
    }

    private func sample() {
        latestSnapshot = Hardware.snapshot()
        let brightness = latestSnapshot.sleeping ? nil : latestSnapshot.source
        timing.sample(brightness, at: .now)
        if source != brightness { source = brightness }
        if brightness == nil, comparisonVisible { closeComparison() }
    }

    func profile(_ id: String) -> Profile { profiles[id] ?? Profile() }

    func adjustment(_ id: String) -> BrightnessAdjustment {
        profile(id).adjustment ?? BrightnessAdjustment()
    }

    func setAdjustment(_ id: String, _ adjustment: BrightnessAdjustment) {
        var profile = profile(id)
        if profile.adjustment?.offset != adjustment.offset { learningMessage[id] = nil }
        profile.adjustment = adjustment
        save(profile, for: id)
    }

    func canRememberOffset(_ id: String) -> Bool {
        let profile = profile(id)
        let adjustment = adjustment(id)
        guard adjustment.offset != 0, !paused, profile.enabled, holds[id] == nil,
              calibrating != id, busy != id, let source,
              case let .ready(value) = links[id] else { return false }
        let original = profile.target(source)
        let adjustedRaw = value.rawValue(for: adjustment.apply(to: original))
        let unadjusted = min(adjustment.maximum, max(adjustment.minimum, original))
        return adjustedRaw == value.raw && adjustedRaw != value.rawValue(for: unadjusted)
    }

    func rememberOffset(_ id: String) {
        guard canRememberOffset(id), let source, Hardware.snapshot().source == source else { return }
        var profile = profile(id)
        guard let point = profile.rememberOffset(at: source) else {
            learningMessage[id] = "这个微调与附近校准点冲突。请减小微调幅度，或在校准中修改对应的点。"
            return
        }
        save(profile, for: id)
        learningMessage[id] = "已记住：内屏 \(point.input)% → 外屏 \(point.output)%"
    }

    func hold(_ id: String, minutes: Int?) {
        holds[id] = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        defaults.set(holds, forKey: "holds")
    }

    func showComparison(_ id: String) {
        guard calibrating == id else { return }
        comparisonVisible = comparison.show(on: id)
    }

    func closeComparison() {
        comparison.close()
        comparisonVisible = false
    }

    private func save(_ profile: Profile, for id: String) {
        profiles[id] = profile
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
    }

    func enable(_ id: String, _ enabled: Bool) {
        var profile = profile(id)
        profile.enabled = enabled
        save(profile, for: id)
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            defaults.set(true, forKey: "loginConfigured")
            loginError = nil
        } catch {
            loginError = "登录项设置失败：\(error.localizedDescription)"
            NSLog("ScreenSync login item: %@", String(describing: error))
        }
        refreshLogin()
        NSLog("ScreenSync login item status: %ld", loginStatus.rawValue)
    }

    func refreshLogin() { loginStatus = SMAppService.mainApp.status }

    func recheck() { recheckRequested = true }

    func endCalibration() {
        calibrating = nil
        message = nil
    }

    func removePoint(_ point: Point, id: String) {
        var profile = profile(id)
        profile.points.removeAll { $0.id == point.id }
        save(profile, for: id)
    }

    func resetCurve(_ id: String) {
        var profile = profile(id)
        profile.points = []
        if let source, let brightness = links[id]?.value {
            profile.baseline = Point(input: source, output: brightness.percent)
        } else {
            profile.baseline = nil
        }
        save(profile, for: id)
    }

    func savePoint(_ id: String) {
        guard busy == nil, calibrating == id, let source = Hardware.snapshot().source,
              case let .ready(value) = links[id] else { return }
        var profile = profile(id)
        if profile.add(Point(input: source, output: value.percent)) {
            save(profile, for: id)
            message = "已保存：内屏 \(source)% → 外屏 \(value.percent)%"
        } else {
            message = "这个校准点会让曲线反向。请调整外屏亮度，或删除冲突的校准点。"
        }
    }

    func setManual(_ id: String, percent: Int) async {
        guard busy == nil, paused || !profile(id).enabled || calibrating == id || holds[id] != nil,
              let value = links[id]?.value else { return }
        message = nil
        await write(id, value: value, raw: value.rawValue(for: percent))
    }

    private func write(_ id: String, value: Backlight, raw: Int) async {
        busy = id
        defer { busy = nil }
        if let verified = await ddc.write(id, raw: raw, max: value.max) {
            links[id] = verified.raw == raw ? .ready(verified) : .mismatch(verified)
        } else {
            links[id] = .failed
        }
        retryAfter[id] = Date().addingTimeInterval(15)
        nextRead[id] = Date().addingTimeInterval(8)
    }

    private func tick() async {
        let snapshot = latestSnapshot
        for (id, end) in holds where end <= Date() { hold(id, minutes: nil) }
        if snapshot.sleeping { recheckRequested = true; return }
        let previous = Set(displays.map(\.id))
        let nowOnline = Set(snapshot.external.map(\.id))
        if previous != nowOnline || recheckRequested {
            if recheckRequested { links.removeAll() }
            links = links.filter { nowOnline.contains($0.key) }
            retryAfter.removeAll()
            nextRead.removeAll()
            recheckRequested = false
        }
        if displays != snapshot.external { displays = snapshot.external }
        if let calibrating, !nowOnline.contains(calibrating) { endCalibration() }
        for display in displays {
            guard busy == nil else { return }
            let id = display.id
            let link = links[id] ?? .probing
            if case .ready = link {
                if Date() >= nextRead[id, default: .distantPast] {
                    await probe(id, max: link.value?.max)
                }
            } else if Date() >= retryAfter[id, default: .distantPast] {
                await probe(id)
            }
            guard let source, latestSnapshot.external.contains(display),
                  !latestSnapshot.sleeping, case let .ready(value) = links[id] else { continue }
            var profile = profile(id)
            if profile.baseline == nil {
                profile.baseline = Point(input: source, output: value.percent)
                save(profile, for: id)
            }
            guard !paused, profile.enabled, calibrating != id, holds[id] == nil,
                  let input = timing.target(at: .now, delay: followDelay) else { continue }
            let percent = adjustment(id).apply(to: profile.target(input))
            let target = value.rawValue(for: percent)
            if target != value.raw { await write(id, value: value, raw: target) }
        }
    }

    private func probe(_ id: String, max knownMax: Int? = nil) async {
        busy = id
        defer { busy = nil }
        if knownMax == nil { links[id] = .probing }
        if let value = await ddc.read(id, max: knownMax) { links[id] = .ready(value) }
        else { links[id] = .failed }
        retryAfter[id] = Date().addingTimeInterval(15)
        nextRead[id] = Date().addingTimeInterval(8)
    }
}
