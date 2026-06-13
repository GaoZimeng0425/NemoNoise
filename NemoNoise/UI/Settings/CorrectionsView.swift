import SwiftUI

/// Editor for the text-correction dictionary. User rules are stored as JSON in
/// `AppDefaults.Keys.textCorrectionRules`; `TextCorrectionProcessor` re-reads
/// them every utterance, so edits here take effect on the next dictation.
struct CorrectionsView: View {
    /// View-local model with a stable identity for the editable list. Kept
    /// separate from the Codable `CorrectionRule` so the persisted JSON stays
    /// `{from, to}` and list rows don't collide while a new row is still empty.
    private struct EditableRule: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var to: String
    }

    @State private var rules: [EditableRule] = []
    @State private var showPresets = false

    var body: some View {
        Form {
            Section {
                if rules.isEmpty {
                    Text("No custom corrections yet. Tap + to add one — e.g. fix “u爱” → “UI”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($rules) { $rule in
                        HStack(spacing: 8) {
                            TextField("Heard as", text: $rule.from)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Replace with", text: $rule.to)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this rule")
                        }
                    }
                }

                Button {
                    rules.append(EditableRule(from: "", to: ""))
                } label: {
                    Label("Add correction", systemImage: "plus")
                }
            } header: {
                Text("My corrections")
            } footer: {
                Text("After recognition, the left text is replaced with the right. Pure-English keys (e.g. “ui”) match only as a whole word and ignore case; keys containing Chinese match literally. Changes apply to your next recording.")
                    .font(.caption)
            }

            Section {
                DisclosureGroup(isExpanded: $showPresets) {
                    ForEach(TextCorrections.presets, id: \.from) { rule in
                        HStack(spacing: 6) {
                            Text(rule.from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(rule.to)
                            Spacer()
                        }
                        .font(.callout)
                    }
                } label: {
                    Text("Built-in presets (\(TextCorrections.presets.count), read-only)")
                }
            } footer: {
                Text("Presets are always active. To override one, add a rule above with the same “Heard as” text.")
                    .font(.caption)
            }
        }
        .onAppear {
            rules = TextCorrections.userRules().map { EditableRule(from: $0.from, to: $0.to) }
        }
        .onChange(of: rules) { _, newValue in
            save(newValue)
        }
    }

    private func save(_ editable: [EditableRule]) {
        let cleaned = editable
            .map { CorrectionRule(from: $0.from.trimmingCharacters(in: .whitespaces), to: $0.to) }
            .filter { !$0.from.isEmpty }
        let data = try? JSONEncoder().encode(cleaned)
        UserDefaults.standard.set(data, forKey: AppDefaults.Keys.textCorrectionRules)
    }
}
