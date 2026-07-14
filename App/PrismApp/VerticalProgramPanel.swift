import PrismCore
import SwiftUI

/// "Vertical (9:16)" controls + live monitor for the second (vertical) program.
///
/// The vertical program is a SECOND full composite of the SAME per-tick source
/// frames as the 16:9 program, reframed to 1080×1920 — roughly another <4 ms
/// GPU pass on its own compositor/queue (it does not add to the primary's <4 ms
/// tick budget). Turning it on lets you record/preview a portrait cut of the
/// same show.
struct VerticalProgramPanel: View {
    @EnvironmentObject private var engine: AppEngine

    private var videoSources: [ActiveSource] {
        engine.activeSources.filter(\.isVideo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { engine.verticalProgramEnabled },
                set: { engine.setVerticalEnabled($0) }
            )) {
                Label("Vertical (9:16)", systemImage: "rectangle.portrait")
                    .font(.headline)
            }
            .toggleStyle(.switch)

            if engine.verticalProgramEnabled {
                Picker("Reframe", selection: Binding(
                    get: { engine.verticalReframeMode },
                    set: { engine.setVerticalReframe($0) }
                )) {
                    ForEach(VerticalReframeMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if engine.verticalReframeMode == .follow {
                    Picker("Hero", selection: Binding(
                        get: { engine.verticalHeroSourceID },
                        set: { engine.setVerticalHero($0) }
                    )) {
                        Text("Frontmost").tag(SourceID?.none)
                        ForEach(videoSources, id: \.id) { source in
                            Text(source.descriptor.name).tag(SourceID?.some(source.id))
                        }
                    }
                    .disabled(videoSources.isEmpty)
                }

                // Live 9:16 monitor (onSecondaryFrame's latest frame).
                ProgramMonitorView(store: engine.verticalPreviewStore)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxWidth: 180)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }
}
