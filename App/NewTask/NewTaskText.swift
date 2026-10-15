import Foundation

/// The New task text field split into a task: the first non-empty line is the
/// title, the rest is the description (nil when blank). Both are trimmed.
struct NewTaskText: Equatable {
    let title: String
    let description: String?
}

extension NewTaskText {
    init(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            self.init(title: "", description: nil)
            return
        }
        let title = lines[index].trimmingCharacters(in: .whitespaces)
        let rest = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(title: title, description: rest.isEmpty ? nil : rest)
    }
}
