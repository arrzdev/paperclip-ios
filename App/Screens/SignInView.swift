import PaperclipAPI
import SwiftUI

/// Server URL entry and device-flow sign-in.
@MainActor
struct SignInView: View {
    @State private var flow: SignInFlow
    private let onSignedIn: (() -> Void)?

    init(store: AccountStore, reauthenticating accountID: UUID? = nil, onSignedIn: (() -> Void)? = nil) {
        _flow = State(initialValue: SignInFlow(
            store: store,
            approval: WebAuthenticationApprovalPresenter(),
            log: store.log,
            reauthenticating: accountID
        ))
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        Form {
            Section {
                TextField("paperclip.example.com", text: $flow.urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit(checkServer)
                    .disabled(isBusy)
            } header: {
                Text("Server")
            } footer: {
                Text("The address of your Paperclip server. You approve the sign-in in the browser; the app never asks for your password.")
            }

            Section {
                actions
            }

            if let warning = flow.versionWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if let error = flow.errorMessage {
                Section {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: flow.state) { _, state in
            if case .signedIn = state { onSignedIn?() }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.state {
        case .editing, .failed:
            Button("Continue", action: checkServer)
                .disabled(flow.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        case .checking:
            ProgressRow(text: "Checking the server…")
        case .ready(let server, _):
            if flow.urlText == server.displayName {
                LabeledContent("Server", value: server.displayName)
                Button("Sign in") {
                    Task { await flow.signIn() }
                }
            } else {
                Button("Continue", action: checkServer)
            }
        case .waitingForApproval:
            ProgressRow(text: "Waiting for approval in the browser…")
        case .signedIn:
            Label("Signed in", systemImage: "checkmark.circle")
        }
    }

    private var isBusy: Bool {
        switch flow.state {
        case .checking, .waitingForApproval: true
        default: false
        }
    }

    private func checkServer() {
        Task { await flow.checkServer() }
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
