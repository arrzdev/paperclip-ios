import SwiftUI

@main
@MainActor
struct PaperclipApp: App {
    @State private var store: AccountStore

    init() {
        let store = AccountStore.live()
        do {
            try store.load()
        } catch {
            store.log("Could not read the accounts file: \(error)")
        }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
