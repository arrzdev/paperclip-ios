import SwiftUI

@main
@MainActor
struct PaperclipApp: App {
    @State private var store: AccountStore

    init() {
        #if DEBUG
        if FixtureMode.isOn {
            _store = State(initialValue: FixtureMode.makeStore())
            return
        }
        #endif
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
                .preferredColorScheme(Self.colorScheme)
        }
    }

    /// The system's choice, except in UI-test mode with `-uiTestDark`.
    private static var colorScheme: ColorScheme? {
        #if DEBUG
        return FixtureMode.prefersDark ? .dark : nil
        #else
        return nil
        #endif
    }
}
