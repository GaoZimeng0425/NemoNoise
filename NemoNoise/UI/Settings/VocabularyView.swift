import SwiftUI

/// Editor for the user vocabulary (recognition-side biasing terms). Terms are
/// stored via `UserLexicon`; the active ASR engine re-reads them when it starts,
/// so edits apply to the next recording. This is distinct from the Corrections
/// tab: corrections rewrite text AFTER recognition, vocabulary biases the
/// recognizer toward producing the term in the first place.
struct VocabularyView: View {
    /// View-local model with a stable identity for the editable list, so rows
    /// don't collide while a new term is still empty.
    private struct EditableTerm: Identifiable, Equatable {
        let id = UUID()
        var term: String
    }

    @State private var terms: [EditableTerm] = []

    var body: some View {
        Form {
            Section {
                if terms.isEmpty {
                    Text("No vocabulary yet. Tap + to add names or jargon you use often — e.g. \u{201C}NemoNoise\u{201D}, \u{201C}sherpa-onnx\u{201D}.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($terms) { $entry in
                        HStack(spacing: 8) {
                            TextField("Term", text: $entry.term)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                terms.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this term")
                        }
                    }
                }

                Button {
                    terms.append(EditableTerm(term: ""))
                } label: {
                    Label("Add term", systemImage: "plus")
                }
            } header: {
                Text("My vocabulary")
            } footer: {
                Text("Vocabulary terms bias recognition toward names and jargon. Works with Qwen3 and Apple Speech; SenseVoice relies on the Corrections list instead. Changes apply to your next recording.")
                    .font(.caption)
            }
        }
        .onAppear {
            terms = UserLexicon.active().map { EditableTerm(term: $0.term) }
        }
        .onChange(of: terms) { _, newValue in
            save(newValue)
        }
    }

    private func save(_ editable: [EditableTerm]) {
        let cleaned = editable
            .map { LexiconEntry(term: $0.term.trimmingCharacters(in: .whitespaces), weight: 2.0) }
            .filter { !$0.term.isEmpty }
        UserLexicon.save(cleaned)
    }
}
