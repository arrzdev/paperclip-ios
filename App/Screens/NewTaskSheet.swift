import PaperclipAPI
import SwiftUI

/// The New task sheet: one text field (first line = title), a photo, an
/// assignee chip and a project chip. Cancel keeps the draft. On success
/// `HomeView` closes the sheet and opens the new task.
@MainActor
struct NewTaskSheet: View {
    @Bindable var model: NewTaskModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var isPreparing = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(model.placeholder, text: $model.text, axis: .vertical)
                        .lineLimit(3...12)
                        .focused($focused)
                        .disabled(model.isBusy)
                    if let image = model.image {
                        PendingThumbnail(image: image, canRemove: !model.isBusy) {
                            model.removeImage()
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryText)
                    }
                    if let loadError = model.loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryText)
                    }
                    if model.phase != .idle {
                        SendBubble(phase: model.phase) {
                            Task { await model.retry() }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        chips
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        chips
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .animation(.snappy, value: model.phase)
            .animation(.snappy, value: model.image == nil)
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        notice = nil
                        Task { await model.send() }
                    }
                    .disabled(!model.canSend || isPreparing)
                }
            }
            .task {
                focused = true
                await model.load()
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        PhotoButton(isDisabled: model.isBusy, isPreparing: $isPreparing, notice: $notice) {
            model.attach($0)
        }
        AssigneeChip(model: model)
        ProjectChip(model: model)
    }
}

/// "Luis ▾": the agents that can take work.
private struct AssigneeChip: View {
    let model: NewTaskModel

    var body: some View {
        Menu {
            ForEach(model.agents) { agent in
                Button {
                    model.selectAssignee(agent)
                } label: {
                    if agent.id == model.assignee?.id {
                        Label(agent.name, systemImage: "checkmark")
                    } else {
                        Text(agent.name)
                    }
                }
            }
        } label: {
            ChipLabel(systemImage: "person.crop.circle", title: model.assignee?.name ?? "Assignee")
        }
        .disabled(model.isBusy || model.agents.isEmpty)
        .accessibilityLabel("Assignee: \(model.assignee?.name ?? "none")")
    }
}

/// "No project ▾" by default; the company's projects to pick from.
private struct ProjectChip: View {
    let model: NewTaskModel

    var body: some View {
        Menu {
            Button {
                model.selectProject(nil)
            } label: {
                if model.project == nil {
                    Label("No project", systemImage: "checkmark")
                } else {
                    Text("No project")
                }
            }
            ForEach(model.projects) { project in
                Button {
                    model.selectProject(project)
                } label: {
                    if project.id == model.project?.id {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        } label: {
            ChipLabel(systemImage: "folder", title: model.project?.name ?? "No project")
        }
        .disabled(model.isBusy)
        .accessibilityLabel("Project: \(model.project?.name ?? "none")")
    }
}

private struct ChipLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(2)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: .capsule)
    }
}

/// The Today bar: "Message <name>… [📷] [➤]". Sends through the same
/// `NewTaskModel` as the sheet, so the draft is shared.
@MainActor
struct MessageBar: View {
    @Bindable var model: NewTaskModel
    @State private var isPreparing = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.phase != .idle {
                SendBubble(phase: model.phase) {
                    Task { await model.retry() }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
            }
            if let image = model.image {
                PendingThumbnail(image: image, canRemove: !model.isBusy) {
                    model.removeImage()
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.placeholder, text: $model.text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background, in: .rect(cornerRadius: 18))
                    .disabled(model.isBusy)
                PhotoButton(isDisabled: model.isBusy, isPreparing: $isPreparing, notice: $notice) {
                    model.attach($0)
                }
                Button {
                    notice = nil
                    Task { await model.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!model.canSend || isPreparing)
                .accessibilityLabel("Send")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .animation(.snappy, value: model.phase)
        .animation(.snappy, value: model.image == nil)
    }
}

extension View {
    /// The floating **+** that opens the New task sheet; nothing when `action` is nil.
    func newTaskButton(_ action: (() -> Void)?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let action {
                NewTaskFloatingButton(action: action)
            }
        }
    }
}

/// The floating **+**, bottom right in thumb reach; it grows with the text size.
private struct NewTaskFloatingButton: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 56

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.tint, in: .circle)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel("New task")
    }
}
