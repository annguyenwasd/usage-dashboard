import SwiftUI
import AppKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var zcode: Loadable<ZCodeQuota> = .idle
    @Published private(set) var startPlan: Loadable<StartPlanQuota> = .idle
    @Published private(set) var deepseek: Loadable<DeepSeekUsage> = .idle
    @Published private(set) var jev: Loadable<Double> = .idle
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    private var jevFetchedAt: Date?

    init(snapshot: Snapshot? = nil) {
        if let snapshot {
            zcode = snapshot.zcode
            startPlan = snapshot.startPlan
            deepseek = snapshot.deepseek
            jev = snapshot.jev
            updatedAt = snapshot.updatedAt
            return
        }
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      String(describing: type(of: window)) != "NSStatusBarWindow" else { return }
                Task { @MainActor in await self?.refresh() }
            }
        ]
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refresh() }
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refresh(forceJev: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if case .idle = zcode { zcode = .loading }
        if case .idle = startPlan { startPlan = .loading }
        if case .idle = deepseek { deepseek = .loading }

        async let quota = loadQuota()
        async let plan = loadStartPlan()
        async let usage = DeepSeekService.fetch()
        // shortcut: each Jev balance probe is a billed decide call, so it is polled at most every 30 min
        if forceJev || jevFetchedAt.map({ Date().timeIntervalSince($0) >= 1800 }) ?? true {
            jev = await loadJev()
            jevFetchedAt = Date()
        }
        let snapshot = Snapshot(zcode: await quota, startPlan: await plan, deepseek: await usage, jev: jev, updatedAt: Date())

        zcode = snapshot.zcode
        startPlan = snapshot.startPlan
        deepseek = snapshot.deepseek
        updatedAt = snapshot.updatedAt
    }

    var menuBarLabel: String {
        var dollars: [String] = []
        if case .loaded(let usage) = deepseek {
            dollars.append("DS $\(money(usage.balanceUSD))")
        }
        if case .loaded(let balance) = jev {
            dollars.append("Jev $\(money(balance))")
        }
        if case .loaded(let quota) = zcode {
            // nested windows: the lower remaining fraction is the one blocking usage, so it leads
            let binding = [quota.fiveHour, quota.week]
                .min(by: { $0.remainingFraction < $1.remainingFraction })!
            let other = binding.id == quota.fiveHour.id ? quota.week : quota.fiveHour
            var warning = binding.remainingFraction < 0.10
            var label = "P \(tag(binding)) \(percent(binding.remainingFraction))%"
            label += " · \(tag(other)) \(percent(other.remainingFraction))%"
            if case .loaded(let plan) = startPlan {
                let pools = plan.windows.map { pool -> String in
                    // strip the GLM- prefix so the bar lists each model without overflowing
                    let name = pool.label.hasPrefix("GLM-") ? String(pool.label.dropFirst(4)) : pool.label
                    return "\(name) \(percent(pool.remainingFraction))%"
                }
                if !pools.isEmpty {
                    label += " │ S " + pools.joined(separator: " · ")
                }
                warning = warning || plan.windows.contains { $0.remainingFraction < 0.10 }
            }
            if !dollars.isEmpty {
                label += " │ " + dollars.joined(separator: " · ")
            }
            return "\(warning ? "⚠ " : "")\(label)"
        }
        if case .failed = zcode {
            if !dollars.isEmpty {
                return "! · " + dollars.joined(separator: " · ")
            }
            if case .failed = deepseek { return "!" }
        }
        return "…"
    }

    private func tag(_ window: QuotaWindow) -> String {
        window.id == "week" ? "wk" : "5h"
    }

    private func loadQuota() async -> Loadable<ZCodeQuota> {
        do {
            return .loaded(try await ZCodeQuotaService.fetchQuota())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func loadStartPlan() async -> Loadable<StartPlanQuota> {
        do {
            return .loaded(try await StartPlanService.fetchBalance())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func loadJev() async -> Loadable<Double> {
        do {
            return .loaded(try await JevService.fetchBalance())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    private func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            quotaSection
            Divider()
            startPlanSection
            Divider()
            balancesSection
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pro Plan").font(.headline)
            if case .loaded(let quota) = store.zcode {
                Text(quota.level.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.zcode {
            case .loaded(let quota):
                quotaRow(quota.fiveHour)
                quotaRow(quota.week)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            case .loading, .idle:
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startPlanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Start Plan").font(.headline)
                if case .loaded(let plan) = store.startPlan {
                    Text(plan.planName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
            }
            switch store.startPlan {
            case .loaded(let plan):
                ForEach(plan.windows) { window in
                    quotaRow(window)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            case .loading, .idle:
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func quotaRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.callout)
                Spacer()
                Text("\(count(window.used)) / \(count(window.total)) used")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(tint(for: window.remainingFraction))
                        .frame(width: max(geometry.size.width * window.usedFraction, 4))
                }
            }
            .frame(height: 6)
            Text("\(count(window.remaining)) left · \(resetText(window.resetsAt, expires: window.expires))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(window.models) { model in
                HStack {
                    Text(model.name)
                    Spacer()
                    Text("\(compact(model.tokens)) · \(Int((model.share * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            }
        }
    }

    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                balanceBlock("DeepSeek API", value: store.deepseek, amount: { String(format: "%.2f", $0.balanceUSD) }, caption: nil)
                    .padding(.trailing, 22)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1)
                balanceBlock("Jev API", value: store.jev, amount: { String(format: "%.2f", $0) }, caption: "prepaid · output tokens free")
                    .padding(.leading, 22)
            }
            if case .loaded(let usage) = store.deepseek {
                if usage.localUsageError != nil {
                    Text("local usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    usageRow("Today", tokens: usage.todayTokens, requests: usage.todayRequests)
                    usageRow("Last 5h", tokens: usage.last5hTokens)
                    usageRow("7 days", tokens: usage.weekTokens, requests: usage.weekRequests)
                }
            }
        }
    }

    private func balanceBlock<T>(_ name: String, value: Loadable<T>, amount: (T) -> String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            switch value {
            case .loaded(let value):
                Text(amount(value))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            case .loading, .idle:
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageRow(_ label: String, tokens: Int, requests: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(compact(tokens)).monospacedDigit()
            if let requests {
                Text("· \(requests) calls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Updating…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Updated \(store.updatedAt.map { Self.clock.string(from: $0) } ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                Task { await store.refresh(forceJev: true) }
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .controlSize(.small)
    }

    private func tint(for remainingFraction: Double) -> Color {
        if remainingFraction < 0.10 { return .red }
        if remainingFraction < 0.30 { return .orange }
        return .accentColor
    }

    private func resetText(_ date: Date?, expires: Bool = false) -> String {
        guard let date else { return expires ? "no expiry" : "no reset time" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return expires ? "expired" : "resets now" }
        let minutes = max(Int(seconds / 60), 1)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        let verb = expires ? "expires" : "resets"
        if days > 0 { return "\(verb) in \(days)d \(hours)h" }
        if hours > 0 { return "\(verb) in \(hours)h \(mins)m" }
        return "\(verb) in \(mins)m"
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private func count(_ value: Double) -> String {
        Self.countFormatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    private func compact(_ tokens: Int) -> String {
        let value = Double(tokens)
        let divisor: Double
        let suffix: String
        if value >= 1_000_000_000 {
            divisor = 1_000_000_000
            suffix = "B"
        } else if value >= 1_000_000 {
            divisor = 1_000_000
            suffix = "M"
        } else if value >= 1_000 {
            divisor = 1_000
            suffix = "K"
        } else {
            return tokens.formatted()
        }
        let text = String(format: "%.1f", value / divisor)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
}
