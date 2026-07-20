import SwiftUI

/// Transport-bar menu for scene collections (v2 deliverable 1): save the
/// current layout under a name and switch between saved ones.
struct SceneCollectionsMenu: View {
    @EnvironmentObject private var engine: AppEngine
    @State private var saveSheetShown = false

    var body: some View {
        Menu {
            Button {
                saveSheetShown = true
            } label: {
                Label("Save Current Layout…", systemImage: "square.and.arrow.down")
            }

            if engine.sceneCollections.isEmpty {
                Divider()
                Text("No saved layouts")
            } else {
                Divider()
                ForEach(engine.sceneCollections) { collection in
                    Menu(collection.name) {
                        Button {
                            engine.loadCollection(collection)
                        } label: {
                            Label("Load", systemImage: "tray.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            engine.deleteCollection(collection)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } label: {
            Label("Scenes", systemImage: "rectangle.stack")
                .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("transport.scenes.menu")
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Scenes — save the current layout under a name and switch between saved layouts.")
        .sheet(isPresented: $saveSheetShown) {
            SaveCollectionSheet(isPresented: $saveSheetShown).environmentObject(engine)
        }
    }
}

/// Prompts for a name and saves the current layout as a collection.
private struct SaveCollectionSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Scene Layout").font(.headline)
            Text("Saves the current layer arrangement (frames, order, opacity, visibility) and preset under a name, to reload later.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 340, alignment: .leading)
            TextField("Layout name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("scenes.save.name.field")
                .frame(width: 340)
            if engine.sceneCollections.contains(where: { $0.name == name.trimmingCharacters(in: .whitespaces) }) {
                Label("Replaces the existing layout with this name.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .accessibilityIdentifier("scenes.save.cancel")
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    engine.saveCurrentAsCollection(name: name)
                    isPresented = false
                }
                .accessibilityIdentifier("scenes.save.confirm")
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
