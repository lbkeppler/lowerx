import AppKit
import SwiftUI

@main
struct LowerXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Precisa vir antes dos modelos: eles leem os ajustes ao serem criados.
    private let migrated: Void = LowerXApp.migrateDefaults()
    @State private var model = HeadsetModel()
    @State private var discord = DiscordCertifier()
    @State private var usb = USBDeviceWatcher()
    @State private var effects = AudioEffects()

    init() {
        // Sem ícone no Dock quando roda via `swift run` (no .app, LSUIElement cuida disso).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("LowerX", id: "main") {
            MainWindow(model: model, discord: discord, usb: usb, effects: effects)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 760)

        MenuBarExtra {
            MenuPanel(model: model, usb: usb, effects: effects)
        } label: {
            MenuBarLabel(model: model)
                .task { discord.certify() }
                .onChange(of: model.dongleAttached) { _, attached in
                    // O dispositivo de áudio aparece um pouco depois do HID.
                    guard attached else { return }
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        discord.certify()
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }

    /// Traz os ajustes da época em que o app se chamava HeadsetBar (outro bundle id).
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromHeadsetBar") else { return }
        defaults.set(true, forKey: "migratedFromHeadsetBar")
        guard let old = UserDefaults(suiteName: "dev.local.headsetbar") else { return }
        for key in ["eqSelection", "eqCustomGains", "spatial", "discordCertify"] {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
}

/// "Encerrar" no Dock ou Cmd-Q na janela só fecham a janela: o LowerX continua na
/// barra de menus (a Saída 7.1 e os efeitos dependem dele rodando). Sai de verdade
/// pelo botão de desligar do painel ou quando o Mac encerra a sessão.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var quitRequested = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitRequested || Self.systemIsQuitting { return .terminateNow }
        for window in sender.windows where window.isVisible { window.close() }
        sender.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    /// Logout, reinício e desligamento mandam o "quit" com um motivo.
    private static var systemIsQuitting: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }
}

/// Ícone da barra de menus: o monograma LX e, com o headset ligado, a bateria.
struct MenuBarLabel: View {
    let model: HeadsetModel

    var body: some View {
        Image(nsImage: Self.glyph)
            .opacity(model.headsetOnline ? 1 : model.dongleAttached ? 0.6 : 0.4)
        if model.headsetOnline, let battery = model.battery {
            Text(model.charging == .charging ? "⚡︎\(battery)%" : "\(battery)%")
        }
    }

    /// "LX" na fonte do app, como imagem template (a barra de menus não usa fontes próprias).
    static let glyph: NSImage = {
        let font = NSFont(name: "Saira-Black", size: 13) ?? .systemFont(ofSize: 13, weight: .black)
        let text = NSAttributedString(string: "LX", attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2 + 0.5))
            // Traço sob o monograma, como no ícone do app.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.width * 0.18, y: 1, width: rect.width * 0.64, height: 1.6),
                         xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Painel da barra de menus, no mesmo visual da janela principal.
struct MenuPanel: View {
    @Bindable var model: HeadsetModel
    let usb: USBDeviceWatcher
    @Bindable var effects: AudioEffects
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.headsetOnline {
                headsetSection
            } else {
                Text(model.dongleAttached ? "Ligue o headset para ver bateria e ajustes."
                                          : "Conecte o receptor USB do headset.")
                    .font(Theme.font(13)).foregroundStyle(Theme.secondaryText)
                    .padding(.vertical, 4)
            }
            audioSection
            if !otherDevices.isEmpty { otherDevicesSection }
            if let message = effects.statusMessage {
                Text(message).font(Theme.font(11)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 330)
        .background(Theme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { model.refresh() }
    }

    // MARK: Topo

    private var header: some View {
        HStack(spacing: 12) {
            ProductImage(model: "Headset_CloudStinger2Wireless")
                .frame(width: 62, height: 54)
                .shadow(color: Theme.accent.opacity(0.35), radius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("CLOUD STINGER 2").font(Theme.font(14, .black))
                Text(statusText).font(Theme.font(11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if model.headsetOnline, let battery = model.battery {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(battery)%").font(Theme.font(20, .black)).monospacedDigit()
                    if model.charging == .charging {
                        Text("carregando").font(Theme.font(10)).foregroundStyle(.yellow)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RadialGradient(colors: [Theme.accent.opacity(0.25), .clear], center: .init(x: 0.12, y: 0.5),
                           startRadius: 4, endRadius: 140),
            in: RoundedRectangle(cornerRadius: 12))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    private var statusText: String {
        if !model.dongleAttached { return "Receptor desconectado" }
        if !model.headsetOnline { return "Headset desligado" }
        return model.microphoneMuted ? "Microfone mutado" : "Microfone ativo"
    }

    // MARK: Headset

    private var headsetSection: some View {
        PanelSection("Headset") {
            SettingRow(title: "Sidetone") {
                Toggle("", isOn: Binding(get: { model.sidetone }, set: { model.setSidetone($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
            }
            PillPicker(options: Stinger.SidetonePreset.allCases.map { (Optional($0), $0.title) },
                       selection: Binding(get: { model.sidetonePreset },
                                          set: { if let preset = $0 { model.setSidetonePreset(preset) } }))
            Text("DESLIGAR AUTOMATICAMENTE").font(Theme.font(10, .bold)).tracking(1.2)
                .foregroundStyle(Theme.tertiaryText).padding(.top, 4)
            PillPicker(options: Stinger.autoOffChoices.map { ($0, $0 == 0 ? "Nunca" : "\($0) min") },
                       selection: Binding(get: { model.autoOff }, set: { model.setAutoOff($0) }))
        }
    }

    // MARK: Áudio

    private var audioSection: some View {
        PanelSection("Áudio") {
            SettingRow(title: "Equalizador") {
                Picker("", selection: $effects.selection) {
                    Text("Desligado").tag(AudioEffects.Selection.off)
                    Divider()
                    ForEach(Equalizer.Preset.allCases) { preset in
                        Text(preset.title).tag(AudioEffects.Selection.preset(preset))
                    }
                    Divider()
                    Text("Personalizado").tag(AudioEffects.Selection.custom)
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(title: "Espacial") {
                Toggle("", isOn: $effects.spatial)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
            }
            if effects.surroundInstalled {
                SettingRow(title: "Saída 7.1") {
                    Toggle("", isOn: Binding(get: { effects.usingSurround }, set: { effects.useSurround($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
                }
            } else {
                SettingRow(title: "Saída 7.1") {
                    Button(effects.installing ? "Instalando…" : effects.surroundNeedsUpdate ? "Atualizar" : "Instalar") {
                        effects.installSurround()
                    }
                    .controlSize(.small).disabled(effects.installing)
                }
            }
        }
    }

    // MARK: Outros

    private var otherDevices: [USBDeviceWatcher.Device] {
        usb.devices.filter { $0.catalog.productID != Stinger.productID }
    }

    private var otherDevicesSection: some View {
        PanelSection("Outros dispositivos") {
            ForEach(otherDevices) { device in
                HStack(spacing: 10) {
                    ProductImage(model: device.catalog.model, category: device.catalog.category)
                        .frame(width: 36, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.catalog.name.replacingOccurrences(of: "HyperX ", with: ""))
                            .font(Theme.font(12, .medium)).lineLimit(1)
                        Text(device.catalog.firmwareUpdateMode ? "Atualização de firmware" : "Detectado")
                            .font(Theme.font(10)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Text("ABRIR LOWERX").font(Theme.font(12, .bold)).tracking(1.2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            Button {
                AppDelegate.quitRequested = true
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 34, height: 32)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Sair do LowerX")
        }
        .padding(.top, 2)
    }
}

/// Bloco do painel: título pequeno em caixa alta e conteúdo num cartão escuro.
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(Theme.font(10, .bold)).tracking(1.4).foregroundStyle(Theme.tertiaryText)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
    }
}
