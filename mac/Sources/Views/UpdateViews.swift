import SwiftUI

/// Aviso flotante cuando hay una versión nueva de thePod.
struct UpdateBanner: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Group {
            switch updater.state {
            case .available(let r):
                card {
                    Label("Hay una versión nueva de thePod (\(r.version))", systemImage: "arrow.down.circle.fill")
                        .font(.callout.bold())
                    HStack {
                        Button("Ahora no") { updater.state = .idle }
                        Button("Actualizar") { updater.download(r) }.buttonStyle(.borderedProminent)
                    }
                }
            case .downloading(let f):
                card {
                    Text("Bajando la actualización…").font(.callout.bold())
                    if let f { ProgressView(value: f).frame(width: 240) } else { ProgressView().progressViewStyle(.linear).frame(width: 240) }
                }
            case .ready(let r):
                card {
                    Label("thePod \(r.version) está lista", systemImage: "checkmark.seal.fill").font(.callout.bold())
                    Text("Se cierra un momento y vuelve a abrirse ya actualizada.").font(.caption).foregroundStyle(Theme.secondary)
                    Button("Reiniciar y actualizar") { updater.restartAndInstall() }.buttonStyle(.borderedProminent)
                }
            default:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.2), value: updater.state)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.5)))
            .shadow(radius: 12)
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Sección de Ajustes → Actualizaciones.
struct UpdateSettingsSection: View {
    @ObservedObject var updater = Updater.shared
    @State private var auto = Updater.checkOnLaunch

    var body: some View {
        Section("Actualizaciones") {
            LabeledContent("Versión instalada", value: "\(Updater.currentVersion) (\(Updater.currentBuild))")
            Toggle("Buscar versiones nuevas al abrir", isOn: $auto)
                .onChange(of: auto) { _, v in Updater.checkOnLaunch = v }
            HStack {
                Button("Buscar ahora") { updater.check() }
                    .disabled(updater.state == .checking)
                switch updater.state {
                case .checking: ProgressView().controlSize(.small)
                case .upToDate: Text("Tienes la última versión").font(.caption).foregroundStyle(Theme.good)
                case .available(let r):
                    Button("Actualizar a \(r.version)") { updater.download(r) }.buttonStyle(.borderedProminent)
                case .downloading(let f): ProgressView(value: f ?? 0).frame(width: 120)
                case .ready: Button("Reiniciar y actualizar") { updater.restartAndInstall() }.buttonStyle(.borderedProminent)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.orange)
                case .idle: EmptyView()
                }
            }
        }
    }
}
