import SwiftUI
import Core

/// Replacement for the chip-cloud catalog picker. Pre-populates from
/// every catalog the repository already uses (union of all
/// `pkginfo.catalogs[]`), so the most common operation — tick a
/// catalog — is one click. Custom names go via the "Add catalog" row.
struct CatalogChecklist: View {
    @Environment(RepositoryStore.self) private var store
    @Binding var selected: [String]
    @State private var pending: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(allCatalogs, id: \.self) { name in
                Toggle(isOn: bindingFor(name)) {
                    HStack(spacing: 6) {
                        Text(name)
                        Spacer(minLength: 0)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tertiary)
                TextField("Add catalog", text: $pending)
                    .textFieldStyle(.plain)
                    .onSubmit(addPending)
                Button("Add", action: addPending)
                    .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private var allCatalogs: [String] {
        let union = Set(store.snapshot.catalogs.map(\.name) + selected)
        return union.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func bindingFor(_ name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { isOn in
                if isOn, !selected.contains(name) { selected.append(name) }
                if !isOn { selected.removeAll { $0 == name } }
            }
        )
    }

    private func addPending() {
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !selected.contains(value) { selected.append(value) }
        pending = ""
    }
}

/// Three-state segmented picker for `supported_architectures`. We expose
/// the three combinations Munki actually understands: arm64 only,
/// x86_64 only, or universal (both). Beats the open chip field.
struct ArchitecturePicker: View {
    @Binding var selected: [SupportedArchitecture]?

    var body: some View {
        Picker("Architectures", selection: choice) {
            Text("Apple Silicon (arm64)").tag(Choice.arm64Only)
            Text("Intel (x86_64)").tag(Choice.x86Only)
            Text("Universal (arm64 / x86_64)").tag(Choice.universal)
            Text("Unspecified").tag(Choice.unspecified)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private enum Choice: Hashable {
        case arm64Only, x86Only, universal, unspecified
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                guard let s = selected else { return .unspecified }
                let names = Set(s.map(\.rawValue))
                if names == ["arm64"] { return .arm64Only }
                if names == ["x86_64"] { return .x86Only }
                if names.contains("arm64") && names.contains("x86_64") { return .universal }
                return .unspecified
            },
            set: { choice in
                switch choice {
                case .arm64Only: selected = [.arm64]
                case .x86Only: selected = [.x86_64]
                case .universal: selected = [.arm64, .x86_64]
                case .unspecified: selected = nil
                }
            }
        )
    }
}
