import AppKit
import SwiftUI
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SyncModel()
    private var wakeObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.recheck() }
        }
        if CommandLine.arguments.contains("--show") {
            NSApp.activate()
        }
    }
}

@main struct ScreenSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            QuickPanel(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.paused ? "sun.max" : "sun.max.fill")
                .accessibilityLabel("屏幕随光")
        }
        .menuBarExtraStyle(.window)

        Window("屏幕随光", id: "settings") {
            Dashboard(model: delegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 740, height: 630)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--show") ? .presented : .suppressed)
    }
}

struct QuickPanel: View {
    @Bindable var model: SyncModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("屏幕随光").font(.headline)
                Spacer()
                Text(model.source.map { "内屏 \($0)%" } ?? "内屏不可用")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("同步外屏亮度", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                .toggleStyle(.switch)
            Divider()
            if model.displays.isEmpty {
                Text("未连接外接显示器").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.displays) { display in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "display").foregroundStyle(.secondary)
                                Text(display.name).lineLimit(1)
                                Spacer()
                                Text(linkText(model.links[display.id])).monospacedDigit().foregroundStyle(.secondary)
                            }
                            HStack {
                                Slider(value: offsetBinding(model, display.id), in: -30...30, step: 1) {
                                    Text("微调")
                                }
                                Text(signedOffset(model.adjustment(display.id).offset))
                                    .monospacedDigit().frame(width: 32, alignment: .trailing)
                            }
                            .disabled(model.paused || !model.profile(display.id).enabled ||
                                      model.holds[display.id] != nil || model.calibrating == display.id)
                            if model.adjustment(display.id).offset != 0 {
                                RememberOffsetButton(model: model, id: display.id)
                            }
                            if let message = model.learningMessage[display.id] {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(height: min(230, model.displays.reduce(CGFloat(0)) { height, display in
                height + 54 + (model.adjustment(display.id).offset != 0 ? 30 : 0)
                    + (model.learningMessage[display.id] == nil ? 0 : 42)
            }))
            Button {
                openWindow(id: "settings")
                NSApp.activate()
            } label: {
                Label("打开设置与校准", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            Button("退出屏幕随光") { NSApp.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
        }
        .padding(17)
        .frame(width: 280)
    }
}

private func signedOffset(_ value: Int) -> String {
    value > 0 ? "+\(value)" : String(value)
}

@MainActor private func offsetBinding(_ model: SyncModel, _ id: String) -> Binding<Double> {
    Binding(get: { Double(model.adjustment(id).offset) }, set: { value in
        var adjustment = model.adjustment(id)
        adjustment.offset = Int(value)
        model.setAdjustment(id, adjustment)
    })
}

private func linkText(_ link: SyncModel.Link?) -> String {
    switch link {
    case let .ready(value): "\(value.percent)%"
    case let .mismatch(value): "回读 \(value.percent)% · 未达到目标"
    case .failed: "DDC/CI 无响应"
    default: "正在检测"
    }
}

struct Dashboard: View {
    @Bindable var model: SyncModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var selected: String?
    @Namespace private var glass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            speedControls
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                if let display = model.displays.first(where: { $0.id == selected }) {
                    DisplayDetail(model: model, display: display).id(display.id)
                } else {
                    ContentUnavailableView("连接外接显示器", systemImage: "display",
                                           description: Text("连接后可检测硬件亮度并设置同步曲线。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 540)
        .onChange(of: model.displays, initial: true) { _, displays in
            if !displays.contains(where: { $0.id == selected }) { selected = displays.first?.id }
        }
        .onChange(of: activeState) { _, _ in model.refreshLogin() }
        .onDisappear { model.endCalibration() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.max.fill").font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("屏幕随光").font(.system(size: 24, weight: .semibold))
                Text(model.source.map { "Mac 内屏亮度  \($0)%" } ?? "内屏不可用，外屏保持当前亮度")
                    .foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.source)
            }
            Spacer()
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { model.paused.toggle() }
                    } label: {
                        Label(model.paused ? "恢复同步" : "暂停同步",
                              systemImage: model.paused ? "play.fill" : "pause.fill")
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("sync", in: glass)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
    }

    private var speedControls: some View {
        HStack(spacing: 10) {
            Text("跟随延迟").font(.callout.weight(.medium))
            Slider(value: Binding(get: { Double(model.followDelay) }, set: { model.setFollowDelay(Int($0)) }),
                   in: 0...5000, step: 50) { Text("跟随延迟") }
                .labelsHidden()
            TextField("毫秒", value: Binding(get: { model.followDelay }, set: model.setFollowDelay),
                      format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 62)
                .accessibilityLabel("跟随延迟（毫秒）")
            Text("毫秒").foregroundStyle(.secondary)
            Button("立即跟随") { model.setFollowDelay(0) }
                .buttonStyle(.glass)
                .disabled(model.followDelay == 0)
        }
        .help("等待内屏亮度稳定指定时间，再更新外屏。0 毫秒表示检测到变化后立即发送。")
        .padding(.horizontal, 22).padding(.bottom, 14)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("外接显示器").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.displays) { display in
                    Button {
                        if selected != display.id { model.endCalibration() }
                        selected = display.id
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "display").font(.system(size: 17))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(display.name).font(.callout.weight(.semibold))
                                Text(linkText(model.links[display.id])).font(.caption)
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == display.id ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == display.id ? .isSelected : [])
                }
            }
            .padding(13)
        }
        .frame(width: 174)
        .background(.thinMaterial)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("登录时启动", isOn: Binding(
                get: { [.enabled, .requiresApproval].contains(model.loginStatus) },
                set: { model.setLogin($0) }
            ))
            if model.loginStatus == .requiresApproval {
                Button("在系统设置中批准") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
            }
            if let error = model.loginError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新检测") { model.recheck() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct DisplayDetail: View {
    @Bindable var model: SyncModel
    let display: Display
    @State private var draft = 0.0
    @State private var showingReset = false

    private var profile: Profile { model.profile(display.id) }
    private var editing: Bool { model.calibrating == display.id }
    private var value: Backlight? { model.links[display.id]?.value }
    private var heldUntil: Date? { model.holds[display.id] }
    private var canAdjust: Bool { editing || model.paused || !profile.enabled || heldUntil != nil }
    private var adjustment: BrightnessAdjustment { model.adjustment(display.id) }

    private var adjustedCurve: [Point] {
        (0...100).map { input in
            Point(input: input, output: adjustment.apply(to: profile.target(input)))
        }
    }

    private func setMinimum(_ value: Int) {
        var updated = adjustment
        updated.minimum = value
        model.setAdjustment(display.id, updated)
    }

    private func setMaximum(_ value: Int) {
        var updated = adjustment
        updated.maximum = value
        model.setAdjustment(display.id, updated)
    }
    private var canSavePoint: Bool {
        guard editing, model.source != nil, model.busy == nil,
              case let .ready(value) = model.links[display.id] else { return false }
        return value.rawValue(for: Int(draft)) == value.raw
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.name).font(.title2.weight(.semibold))
                        Text(linkText(model.links[display.id])).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Toggle("同步此屏", isOn: Binding(get: { profile.enabled },
                                                   set: { model.enable(display.id, $0) }))
                        .toggleStyle(.switch)
                }
                CurveView(points: editing ? profile.curve : adjustedCurve, source: model.source,
                          target: model.source.map { input in
                    editing ? profile.target(input) : adjustment.apply(to: profile.target(input))
                })
                if !editing {
                    HStack {
                        Slider(value: offsetBinding(model, display.id), in: -30...30, step: 1) {
                            Text("微调")
                        }
                        Text("\(signedOffset(adjustment.offset)) 格").monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        RememberOffsetButton(model: model, id: display.id)
                    }
                    if let message = model.learningMessage[display.id] {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Stepper(value: Binding(get: { adjustment.minimum }, set: setMinimum),
                                in: 0...adjustment.maximum) {
                            Text("最低 \(adjustment.minimum)%").monospacedDigit()
                        }
                        Spacer()
                        Stepper(value: Binding(get: { adjustment.maximum }, set: setMaximum),
                                in: adjustment.minimum...100) {
                            Text("最高 \(adjustment.maximum)%").monospacedDigit()
                        }
                    }
                    HStack {
                        Menu("临时接管") {
                            ForEach([5, 15, 30, 60], id: \.self) { minutes in
                                Button("\(minutes) 分钟") { model.hold(display.id, minutes: minutes) }
                            }
                        }
                        .fixedSize()
                        .disabled(value == nil)
                        if let heldUntil {
                            Text("暂停至 \(heldUntil.formatted(date: .omitted, time: .shortened))")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("结束接管") { model.hold(display.id, minutes: nil) }.buttonStyle(.glass)
                        }
                    }
                }
                if canAdjust, let value {
                    HStack {
                        Slider(value: $draft, in: 0...100, step: 1) { Text("外屏亮度") }
                        Text("\(Int(draft))%").monospacedDigit().frame(width: 45, alignment: .trailing)
                        Button("应用亮度") { Task { await model.setManual(display.id, percent: Int(draft)) } }
                            .buttonStyle(.glass)
                            .disabled(model.busy != nil || value.rawValue(for: Int(draft)) == value.raw)
                    }
                }
                if editing {
                    Text("把内屏调到想校准的亮度，再调节外屏并应用。两块屏幕看起来接近时，保存当前亮度组合。微调和亮度范围会在校准结束后应用。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if editing {
                        Button("保存当前校准点") { model.savePoint(display.id) }
                            .buttonStyle(.glassProminent)
                            .disabled(!canSavePoint)
                        Button("完成校准") { model.endCalibration() }.buttonStyle(.glass)
                        Button(model.comparisonVisible ? "关闭对照" : "显示对照") {
                            if model.comparisonVisible { model.closeComparison() }
                            else { model.showComparison(display.id) }
                        }
                        .buttonStyle(.glass)
                        .disabled(model.source == nil && !model.comparisonVisible)
                    } else {
                        Button("校准亮度") {
                            model.message = nil
                            draft = Double(value?.percent ?? 0)
                            model.calibrating = display.id
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(value == nil || model.source == nil || model.busy != nil)
                    }
                    Spacer()
                    if !profile.points.isEmpty {
                        Button("重置曲线", role: .destructive) { showingReset = true }.buttonStyle(.borderless)
                    }
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(profile.points) { point in
                    HStack {
                        Text("内屏 \(point.input)%").monospacedDigit().frame(width: 94, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text("外屏 \(point.output)%").monospacedDigit()
                        Spacer()
                        if editing {
                            Button("删除", role: .destructive) { model.removePoint(point, id: display.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: value?.percent, initial: true) { _, percent in
            if let percent { draft = Double(percent) }
        }
        .onChange(of: canAdjust) { _, adjusting in
            if adjusting, let value { draft = Double(value.percent) }
        }
        .confirmationDialog("删除此屏的全部校准点？", isPresented: $showingReset) {
            Button("重置曲线", role: .destructive) { model.resetCurve(display.id) }
        }
    }
}

private struct RememberOffsetButton: View {
    let model: SyncModel
    let id: String
    var body: some View {
        Button("记住这次微调") { model.rememberOffset(id) }
            .buttonStyle(.glass)
            .disabled(!model.canRememberOffset(id))
            .help("将当前亮度组合存为此屏的校准点，再把全局微调归零。外屏达到目标亮度后可保存。")
    }
}

struct CurveView: View {
    let points: [Point]
    let source: Int?
    let target: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("外屏亮度").font(.caption.weight(.medium))
                Spacer()
                if let source, let target {
                    Text("内屏 \(source)% → 目标 \(target)%").font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            Canvas { context, size in
                func location(_ input: Int, _ output: Int) -> CGPoint {
                    CGPoint(x: 6 + (size.width - 12) * CGFloat(input) / 100,
                            y: size.height - 6 - (size.height - 12) * CGFloat(output) / 100)
                }
                for mark in [0, 25, 50, 75, 100] {
                    var grid = Path()
                    grid.move(to: location(0, mark))
                    grid.addLine(to: location(100, mark))
                    grid.move(to: location(mark, 0))
                    grid.addLine(to: location(mark, 100))
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                }
                guard let first = points.first else { return }
                var line = Path()
                line.move(to: location(first.input, first.output))
                for point in points.dropFirst() { line.addLine(to: location(point.input, point.output)) }
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let source, let target {
                    let point = location(source, target)
                    let dot = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    context.fill(dot, with: .color(.accentColor))
                }
            }
            .frame(height: 130)
            .accessibilityHidden(true)
            HStack {
                Text("0%")
                Spacer()
                Text("内屏亮度")
                Spacer()
                Text("100%")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
}
