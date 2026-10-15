import PaperclipAPI
import SwiftUI

// Me → More (read only): Agents, Activity, Approvals, Goals, Costs and
// "Open in web" for everything the app leaves out.

/// The More sections at the bottom of the Me tab.
@MainActor
struct MoreSection: View {
    let model: MoreModel

    var body: some View {
        Section {
            NavigationLink {
                AgentsView(store: model.store, accountID: model.accountID)
            } label: {
                RowLabel("Agents", systemImage: "person.2")
            }
            NavigationLink {
                ActivityView(store: model.store, accountID: model.accountID)
            } label: {
                RowLabel("Activity", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink {
                ApprovalsHistoryView(store: model.store, accountID: model.accountID)
            } label: {
                RowLabel("Approvals", systemImage: "checkmark.seal")
            }
            NavigationLink {
                GoalsView(store: model.store, accountID: model.accountID)
            } label: {
                RowLabel("Goals", systemImage: "target")
            }
            NavigationLink {
                CostsView(store: model.store, accountID: model.accountID)
            } label: {
                RowLabel("Costs", systemImage: "dollarsign.circle")
            }
        } header: {
            SectionTitle("More")
        }
        Section {
            ForEach(WebLink.cut, id: \.self) { link in
                WebLinkRow(link: link, url: model.url(for: link))
            }
        } header: {
            SectionTitle("Open in web")
        } footer: {
            SectionTitle("These open \(model.companyName ?? "the company") in the browser.", font: .footnote)
        }
    }
}

/// A web page row: opens in the browser; dimmed until the company prefix is known.
private struct WebLinkRow: View {
    let link: WebLink
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack {
                    RowLabel(link.title, systemImage: link.systemImage)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint("Opens in the browser")
        } else {
            RowLabel(link.title, systemImage: link.systemImage, tintsIcon: false)
                .foregroundStyle(Color.secondaryText)
                .accessibilityHint("Not available yet")
        }
    }
}

// MARK: - Shared states

/// Loading, empty, error and sign-in for the More screens.
@MainActor
private struct MoreOverlay<Value: Equatable>: View {
    let state: LoadState<Value>
    let what: String
    let emptyTitle: String
    let emptyImage: String
    let retry: () async -> Void

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
        case .loaded:
            EmptyView()
        case .empty:
            ContentUnavailableView(emptyTitle, systemImage: emptyImage)
        case .error(let message):
            ContentUnavailableView {
                Label("Could not load \(what)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await retry() }
                }
            }
        case .needsSignIn:
            ContentUnavailableView(
                "Sign in again",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("The server rejected the key for this account.")
            )
        }
    }
}

// MARK: - Agents

/// The company's agents with status and live run, polled while on screen.
@MainActor
struct AgentsView: View {
    @State private var model: AgentsModel

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: AgentsModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let rows) = model.state {
                ForEach(rows) { row in
                    NavigationLink(value: AgentRoute(agentID: row.id)) {
                        AgentRowView(row: row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.state)
        .overlay {
            MoreOverlay(state: model.state, what: "the agents", emptyTitle: "No agents", emptyImage: "person.2") {
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await model.runPolling()
        }
        .navigationTitle("Agents")
    }
}

private struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(color: row.agent.agentStatus.color, label: row.agent.agentStatus.label)
            VStack(alignment: .leading, spacing: 2) {
                AdaptiveRow {
                    Text(row.agent.name)
                        .font(.body.weight(.semibold))
                } trailing: {
                    Text(row.agent.agentStatus.label)
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                if let title = row.agent.title ?? row.agent.role {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryText)
                }
                if row.liveRun != nil {
                    RowLabel("Working now", systemImage: "bolt.fill", font: .footnote)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One agent: status, live run, its web page, and Pause / Resume at the
/// bottom (Pause asks first). Polled while on screen.
@MainActor
struct AgentDetailView: View {
    @State private var model: AgentDetailModel
    @State private var confirmsPause = false
    private let more: MoreModel?

    init(store: AccountStore, accountID: UUID, agentID: String, more: MoreModel?) {
        _model = State(initialValue: AgentDetailModel(store: store, accountID: accountID, agentID: agentID))
        self.more = more
    }

    var body: some View {
        List {
            if let agent = model.agent {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.name)
                            .font(.title3.weight(.semibold))
                        if let title = agent.title ?? agent.role {
                            Text(title)
                                .foregroundStyle(Color.secondaryText)
                        }
                        HStack(spacing: 6) {
                            StatusDot(color: agent.agentStatus.color, label: "")
                                .accessibilityHidden(true)
                            Text(agent.agentStatus.label)
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Status: \(agent.agentStatus.label)")
                    }
                    .padding(.vertical, 2)
                    if let reason = agent.pauseReason, agent.agentStatus == .paused {
                        LabeledContent("Paused because", value: reason)
                    }
                    if let date = agent.lastHeartbeatAt {
                        LabeledContent("Last run") {
                            Text(date, format: .relative(presentation: .named))
                        }
                    }
                }
                Section("Live run") {
                    if let run = model.liveRun {
                        NavigationLink(value: RunLogRoute(runID: run.id, isLive: true, issueID: run.issueId)) {
                            Label(run.status == "queued" ? "Queued: see the log" : "Running: see the log", systemImage: "bolt.fill")
                        }
                        if let issueID = run.issueId {
                            NavigationLink(value: TaskRoute(issueID: issueID)) {
                                Label("The task it works on", systemImage: "checklist")
                            }
                        }
                    } else {
                        Text("Not running now.")
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                if let urlKey = agent.urlKey, let url = more?.url(for: .agent(urlKey: urlKey)) {
                    Section {
                        Link(destination: url) {
                            Label("Open in web", systemImage: "safari")
                        }
                        .accessibilityHint("Config, runs and budget in the browser")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.state)
        .animation(.default, value: model.liveRun)
        .overlay {
            MoreOverlay(state: model.state, what: "the agent", emptyTitle: "No agent", emptyImage: "person") {
                await model.refresh()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await Poller.live.run { await model.poll() }
        }
        .navigationTitle(model.agent?.name ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Pause \(model.agent?.name ?? "the agent")?",
            isPresented: $confirmsPause,
            titleVisibility: .visible
        ) {
            Button("Pause", role: .destructive) {
                Task { await model.pause() }
            }
        } message: {
            Text("Its running work stops. Resume it when you are ready.")
        }
    }

    /// Pause / Resume in thumb reach, with the server's reason when it refused.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let message = model.actionError {
                ActionErrorBanner(message: message) { model.dismissActionError() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.canPause {
                Button {
                    confirmsPause = true
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isSending)
            } else if model.canResume {
                Button {
                    Task { await model.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSending)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            if model.canPause || model.canResume {
                Rectangle().fill(.bar).ignoresSafeArea()
            }
        }
        .animation(.snappy, value: model.actionError)
        .animation(.snappy, value: model.canPause)
    }
}

extension AgentStatus {
    /// System colours: they adapt to dark mode.
    var color: Color {
        switch self {
        case .running: .green
        case .active, .idle: .blue
        case .paused: .orange
        case .error: .red
        case .pendingApproval: .yellow
        case .terminated, .unknown: .secondaryText
        }
    }
}

// MARK: - Run log

/// A run's output, monospaced and selectable, with "Load more"; a live run
/// polls for new lines while on screen. The text is never logged.
@MainActor
struct RunLogView: View {
    @State private var model: RunLogModel
    private let issueID: String?

    init(store: AccountStore, accountID: UUID, route: RunLogRoute) {
        _model = State(initialValue: RunLogModel(store: store, accountID: accountID, runID: route.runID, isLive: route.isLive))
        issueID = route.issueID
    }

    var body: some View {
        List {
            if case .loaded(let lines) = model.state {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        RunLogLineView(line: line)
                    }
                }
                if model.hasMore {
                    Section {
                        Button {
                            Task { await model.loadMore() }
                        } label: {
                            HStack {
                                Text(model.pageError == nil ? "Load more" : "Try again")
                                Spacer()
                                if model.isLoadingMore {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(model.isLoadingMore)
                        if let message = model.pageError {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            MoreOverlay(state: model.state, what: "the log", emptyTitle: "No output yet", emptyImage: "text.alignleft") {
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            if model.isLive {
                await Poller.live.run { await model.poll() }
            }
        }
        .toolbar {
            if let issueID {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: TaskRoute(issueID: issueID)) {
                        Label("Task", systemImage: "checklist")
                    }
                    .accessibilityLabel("Open the task")
                }
            }
        }
        .navigationTitle("Run log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RunLogLineView: View {
    let line: RunLogLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.footnote.monospaced())
            .foregroundStyle(line.stream == "stderr" ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            .listRowSeparator(.hidden)
            .accessibilityLabel(line.stream == "stderr" ? "Error output: \(line.text)" : line.text)
    }
}

// MARK: - Activity

/// The company's recent events; task events open the task.
@MainActor
struct ActivityView: View {
    @State private var model: ActivityModel

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: ActivityModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let rows) = model.state {
                ForEach(rows) { row in
                    if let route = row.taskRoute {
                        NavigationLink(value: route) {
                            ActivityRowView(row: row)
                        }
                    } else {
                        ActivityRowView(row: row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            MoreOverlay(state: model.state, what: "the activity", emptyTitle: "No activity yet", emptyImage: "clock") {
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .navigationTitle("Activity")
    }
}

private struct ActivityRowView: View {
    let row: ActivityRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(row.actor)
                    .font(.subheadline.weight(.semibold))
            } trailing: {
                Text(row.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            Text(row.text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Approvals history

/// Every approval of the company, newest first; a row opens Approval detail.
@MainActor
struct ApprovalsHistoryView: View {
    @State private var model: ApprovalsHistoryModel

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: ApprovalsHistoryModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let approvals) = model.state {
                ForEach(approvals) { approval in
                    NavigationLink(value: ApprovalsHistoryModel.route(for: approval)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(approval.title)
                                .font(.body.weight(.semibold))
                            AdaptiveRow {
                                Label(approval.status.label, systemImage: approval.status.systemImage)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondaryText)
                            } trailing: {
                                Text(approval.createdAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(Color.secondaryText)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            MoreOverlay(state: model.state, what: "the approvals", emptyTitle: "No approvals", emptyImage: "checkmark.seal") {
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .navigationTitle("Approvals")
    }
}

// MARK: - Goals

/// The company's goals as a tree (indented by depth).
@MainActor
struct GoalsView: View {
    @State private var model: GoalsModel
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 16

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: GoalsModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let rows) = model.state {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.goal.title)
                            .font(row.depth == 0 ? .body.weight(.semibold) : .body)
                        let meta = [row.goal.level, row.goal.status]
                            .compactMap { $0?.replacingOccurrences(of: "_", with: " ").capitalized }
                            .joined(separator: " · ")
                        if !meta.isEmpty {
                            Text(meta)
                                .font(.caption)
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                    .padding(.leading, CGFloat(min(row.depth, 4)) * indent)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(row.depth == 0 ? "" : "Level \(row.depth + 1)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            MoreOverlay(state: model.state, what: "the goals", emptyTitle: "No goals", emptyImage: "target") {
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .navigationTitle("Goals")
    }
}

// MARK: - Costs

/// What the company spent against its budget.
@MainActor
struct CostsView: View {
    @State private var model: CostsModel

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: CostsModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let line) = model.state {
                Section {
                    Text(line.text)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                Section {
                    LabeledContent("Spent", value: line.spent)
                    LabeledContent("Budget", value: line.budget ?? "No budget")
                    if let utilization = line.utilization {
                        LabeledContent("Used", value: utilization)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            MoreOverlay(state: model.state, what: "the costs", emptyTitle: "No costs", emptyImage: "dollarsign.circle") {
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .navigationTitle("Costs")
    }
}
