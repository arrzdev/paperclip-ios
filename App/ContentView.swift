import PaperclipAPI
import SwiftUI

struct ContentView: View {
    static let title = "Paperclip"
    static let pinLabel = "Paperclip \(PaperclipPin.version) (\(PaperclipPin.commit))"

    var body: some View {
        VStack(spacing: 8) {
            Text(Self.title)
                .font(.largeTitle)
            Text(Self.pinLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
