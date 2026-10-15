import PaperclipAPI
import SwiftUI

/// The current account's companies; choosing one saves it for that account.
@MainActor
struct CompanyPickerView: View {
    @State private var model: CompanyPickerModel
    @State private var hasLoaded = false
    @State private var selectError: String?

    init(store: AccountStore) {
        _model = State(initialValue: CompanyPickerModel(store: store))
    }

    var body: some View {
        List {
            ForEach(model.companies) { company in
                Button {
                    select(company)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(company.name)
                            if let prefix = company.issuePrefix {
                                Text(prefix)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if company.id == model.selectedCompanyId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(company.id == model.selectedCompanyId ? .isSelected : [])
            }
            if let selectError {
                Text(selectError)
                    .foregroundStyle(.red)
            }
        }
        .overlay {
            if !hasLoaded || (model.isLoading && model.companies.isEmpty) {
                ProgressView()
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Could not load companies", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") {
                        Task { await model.load() }
                    }
                }
            } else if model.companies.isEmpty {
                ContentUnavailableView(
                    "No companies",
                    systemImage: "building.2",
                    description: Text("This account is not a member of any company on this server.")
                )
            }
        }
        .navigationTitle("Company")
        .task {
            await model.load()
            hasLoaded = true
        }
        .refreshable {
            await model.load()
        }
    }

    private func select(_ company: Company) {
        do {
            try model.select(company)
            selectError = nil
        } catch {
            selectError = userMessage(for: error)
        }
    }
}
