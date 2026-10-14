import AppKit
import ServiceManagement
import SwiftUI

/// Janela principal no estilo do NGENUITY: aparelhos à esquerda, com a foto do
/// produto, e as páginas de ajuste à direita.
struct MainWindow: View {
    let model: HeadsetModel
    let discord: DiscordCertifier
    let usb: USBDeviceWatcher
    let effects: AudioEffects

    enum Page: Hashable {
        case stinger
        case sound
        case device(UInt32)
        case settings
    }

    /// `-initialPage settings` / `-initialTab headset` na linha de comando abrem
    /// direto nessas telas (usado para as capturas do README).
    @State private var page: Page = {
        switch UserDefaults.standard.string(forKey: "initialPage") {
        case "settings": return .settings
        case "sound": return .sound
        default: return .stinger
        }
    }()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                switch page {
                case .stinger:
                    StingerPage(model: model, effects: effects)
                case .device(let id):
                    if let device = otherDevices.first(where: { $0.id == id }) {
                        OtherDevicePage(device: device)
                    } else {
                        StingerPage(model: model, effects: effects)
                    }
                case .sound:
                    SoundPage(effects: effects)
                case .settings:
                    SettingsPage(discord: discord, effects: effects)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 940, minHeight: 640)
        .onAppear {
            // Com a janela aberta o app aparece no Dock e no Cmd-Tab; fechada, volta
            // a ser só o ícone da barra de menus.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            model.refresh()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var otherDevices: [USBDeviceWatcher.Device] {
        usb.devices.filter { $0.catalog.productID != Stinger.productID }
    }

    // MARK: - Barra lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent).frame(width: 4, height: 20)
                HStack(spacing: 0) {
                    Text("LOWER").foregroundStyle(.white)
                    Text("X").foregroundStyle(Theme.accent)
                }
                .font(Theme.font(19, .black)).tracking(2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 18)

            Text("ÁUDIO")
                .font(Theme.font(10, .bold)).tracking(1.5)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            SoundRow(output: effects.outputName ?? "Sem saída", active: effects.state == .active,
                     selected: page == .sound) { page = .sound }
                .padding(.bottom, 14)

            Text("DISPOSITIVOS")
                .font(Theme.font(10, .bold)).tracking(1.5)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            DeviceRow(model: "Headset_CloudStinger2Wireless", name: "Cloud Stinger 2 Wireless",
                      status: stingerStatus, selected: page == .stinger) { page = .stinger }
            ForEach(otherDevices) { device in
                DeviceRow(model: device.catalog.model, category: device.catalog.category,
                          name: device.catalog.name.replacingOccurrences(of: "HyperX ", with: ""),
                          status: device.catalog.firmwareUpdateMode ? "Atualização de firmware" : "Conectado",
                          selected: page == .device(device.id)) { page = .device(device.id) }
            }
            Spacer()
            Button { page = .settings } label: {
                Label("Ajustes", systemImage: "gearshape")
                    .font(Theme.font(13, .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .foregroundStyle(page == .settings ? Color.white : Theme.secondaryText)
                    .background(page == .settings ? Theme.cardRaised : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 250)
        .background(Theme.sidebar)
    }

    private var stingerStatus: String {
        if !model.dongleAttached { return "Receptor desconectado" }
        if !model.headsetOnline { return "Desligado" }
        guard let battery = model.battery else { return "Conectado" }
        return model.charging == .charging ? "Carregando · \(battery)%" : "Bateria \(battery)%"
    }
}

private struct SoundRow: View {
    let output: String
    let active: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                    .frame(width: 54, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Som do Mac").font(Theme.font(13, .medium))
                    Text(output).font(Theme.font(11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? Theme.cardRaised : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 26).offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

private struct DeviceRow: View {
    let model: String
    var category: DeviceCatalog.Category = .headset
    let name: String
    let status: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProductImage(model: model, category: category)
                    .frame(width: 54, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(Theme.font(13, .medium)).lineLimit(2)
                    Text(status).font(Theme.font(11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? Theme.cardRaised : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 26).offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

// MARK: - Stinger 2

private struct StingerPage: View {
    @Bindable var model: HeadsetModel
    @Bindable var effects: AudioEffects

    enum Tab: Hashable { case audio, headset }
    @State private var tab: Tab = UserDefaults.standard.string(forKey: "initialTab") == "headset" ? .headset : .audio

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                tabs
                if model.headsetOnline || tab == .audio {
                    switch tab {
                    case .audio: audioTab
                    case .headset: headsetTab
                    }
                } else {
                    Card("Headset") {
                        Text(model.dongleAttached
                             ? "Ligue o headset para ver bateria e ajustes."
                             : "Conecte o receptor USB do headset.")
                            .font(Theme.font(14)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Topo

    private var hero: some View {
        HStack(spacing: 28) {
            ProductImage(model: "Headset_CloudStinger2Wireless")
                .frame(width: 260, height: 220)
                .shadow(color: Theme.accent.opacity(0.25), radius: 40)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HYPERX").font(Theme.font(13, .bold)).tracking(3).foregroundStyle(Theme.accent)
                    Text("CLOUD STINGER 2\nWIRELESS").font(Theme.font(30, .black)).lineSpacing(-4)
                }
                HStack(spacing: 8) {
                    StatusChip(text: connectionText, color: model.headsetOnline ? .green : Theme.tertiaryText)
                    if model.headsetOnline {
                        StatusChip(text: model.microphoneMuted ? "Microfone mutado" : "Microfone ativo",
                                   color: model.microphoneMuted ? Theme.accent : .green)
                    }
                }
                if model.headsetOnline, let battery = model.battery {
                    BatteryBar(level: battery, charging: model.charging)
                        .frame(maxWidth: 300)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .init(x: 0.22, y: 0.5),
                           startRadius: 10, endRadius: 320),
            in: RoundedRectangle(cornerRadius: 16))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
    }

    private var connectionText: String {
        if !model.dongleAttached { return "Receptor desconectado" }
        if !model.headsetOnline { return "Headset desligado" }
        switch model.charging {
        case .charging: return "Conectado · carregando"
        case .full: return "Conectado · carga completa"
        case .error: return "Conectado · erro de carga"
        case .none: return "Conectado"
        }
    }

    private var tabs: some View {
        HStack(spacing: 26) {
            ForEach([(Tab.audio, "ÁUDIO"), (Tab.headset, "HEADSET")], id: \.0) { value, title in
                Button { tab = value } label: {
                    VStack(spacing: 7) {
                        Text(title).font(Theme.font(14, .bold)).tracking(1.5)
                            .foregroundStyle(tab == value ? Color.white : Theme.secondaryText)
                        Rectangle().fill(tab == value ? Theme.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 4)
    }

    // MARK: Áudio

    private var audioTab: some View {
        AudioEffectsSection(effects: effects, showSurround: true)
    }

    // MARK: Headset

    private var headsetTab: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Card("Sidetone") {
                    SettingRow(title: "Ouvir a própria voz", detail: "Retorno do microfone no fone.") {
                        Toggle("", isOn: Binding(get: { model.sidetone }, set: { model.setSidetone($0) }))
                            .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                    }
                    PillPicker(options: Stinger.SidetonePreset.allCases.map { (Optional($0), $0.title) },
                               selection: Binding(get: { model.sidetonePreset },
                                                  set: { if let preset = $0 { model.setSidetonePreset(preset) } }))
                }
                Card("Microfone") {
                    HStack(spacing: 14) {
                        Image(systemName: model.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(model.microphoneMuted ? Theme.accent : .green)
                            .frame(width: 44, height: 44)
                            .background(Theme.cardRaised, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.microphoneMuted ? "Mutado" : "Ativo").font(Theme.font(15, .bold))
                            Text(model.microphoneMuted ? "Haste levantada" : "Haste abaixada")
                                .font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            Card("Energia") {
                SettingRow(title: "Desligar automaticamente", detail: "Sem áudio por este tempo, o headset desliga.") {
                    PillPicker(options: Stinger.autoOffChoices.map { ($0, $0 == 0 ? "Nunca" : "\($0) min") },
                               selection: Binding(get: { model.autoOff }, set: { model.setAutoOff($0) }))
                }
            }
        }
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.font(12, .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.cardRaised, in: Capsule())
    }
}

struct BatteryBar: View {
    let level: Int
    let charging: Stinger.Charging

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BATERIA").font(Theme.font(11, .bold)).tracking(1.4).foregroundStyle(Theme.secondaryText)
                if charging == .charging {
                    Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                }
                Spacer()
                Text("\(level)%").font(Theme.font(20, .black)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardRaised)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(level) / 100)
                }
            }
            .frame(height: 6)
        }
    }

    private var color: Color {
        level <= 15 ? Theme.accent : level <= 30 ? .orange : .green
    }
}

// MARK: - Efeitos de áudio (qualquer saída)

/// EQ e espacial, aplicados na saída de som atual do Mac (qualquer fone ou alto-falante).
/// A Saída 7.1 só aparece na página do Stinger, o único fone em que ela foi validada.
struct AudioEffectsSection: View {
    @Bindable var effects: AudioEffects
    var showSurround = false

    var body: some View {
        VStack(spacing: 18) {
            Card("Equalizador", trailing: AnyView(trailing)) {
                presetChips
                EqualizerGraph(gains: effects.gains, enabled: effects.selection != .off) { band, gain in
                    // Mexer num preset vira "Personalizado" a partir dele.
                    if effects.selection != .custom {
                        effects.customGains = effects.gains
                        effects.selection = .custom
                    }
                    effects.customGains[band] = gain
                }
                .frame(height: 230)
                if effects.selection == .off {
                    Text("Escolha um preset ou arraste os pontos para criar o seu.")
                        .font(Theme.font(12)).foregroundStyle(Theme.tertiaryText)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                Card("Espacial") {
                    SettingRow(title: "Som à frente",
                               detail: "Músicas e vídeos em estéreo soam como alto-falantes à sua frente. Feito para fones.") {
                        Toggle("", isOn: $effects.spatial).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                    }
                }
                if showSurround {
                    Card("Surround 7.1") { surroundCard }
                }
            }
            if let message = effects.statusMessage {
                Label(message, systemImage: "info.circle")
                    .font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Onde os efeitos estão sendo aplicados, e o "Zerar" do modo personalizado.
    private var trailing: some View {
        HStack(spacing: 14) {
            if let name = effects.outputName {
                Label(name, systemImage: effects.usingSurround ? "hifispeaker.2" : "headphones")
                    .font(Theme.font(12, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            if effects.selection == .custom {
                Button("Zerar") { effects.customGains = Equalizer.flat }
                    .buttonStyle(.plain).font(Theme.font(12, .medium)).foregroundStyle(Theme.accent)
            }
        }
    }

    private var presetChips: some View {
        let options: [(AudioEffects.Selection, String)] = [(.off, "Desligado")]
            + Equalizer.Preset.allCases.map { (.preset($0), $0.title) }
            + [(.custom, "Personalizado")]
        return PillPicker(options: options, selection: $effects.selection)
    }

    @ViewBuilder
    private var surroundCard: some View {
        if effects.surroundInstalled {
            SettingRow(title: "Saída 7.1",
                       detail: effects.usingSurround
                           ? "Jogos e filmes em 7.1, posicionados em 3D."
                           : "Apps passam a ver uma saída 7.1 que toca no Stinger 2.") {
                Toggle("", isOn: Binding(get: { effects.usingSurround }, set: { effects.useSurround($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
        } else {
            SettingRow(title: "Saída 7.1",
                       detail: effects.surroundNeedsUpdate
                           ? "Atualiza a saída antiga “HeadsetBar 7.1” para “LowerX 7.1”."
                           : "Instala uma saída de som 7.1 que toca no Stinger 2.") {
                Button(effects.installing ? "Instalando…" : effects.surroundNeedsUpdate ? "Atualizar" : "Instalar") {
                    effects.installSurround()
                }
                .disabled(effects.installing)
            }
        }
    }
}

/// Página "Som do Mac": EQ e espacial para qualquer saída, com ou sem o Stinger.
private struct SoundPage: View {
    let effects: AudioEffects

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SOM DO MAC").font(Theme.font(26, .black)).tracking(1)
                    Text("Equalizador e espacial em qualquer fone ou alto-falante: valem para a saída de som escolhida no Mac.")
                        .font(Theme.font(13)).foregroundStyle(Theme.secondaryText)
                }
                AudioEffectsSection(effects: effects)
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Outros aparelhos

private struct OtherDevicePage: View {
    let device: USBDeviceWatcher.Device

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ProductImage(model: device.catalog.model, category: device.catalog.category)
                .frame(maxWidth: 420, maxHeight: 300)
                .shadow(color: Theme.accent.opacity(0.2), radius: 40)
            Text(device.catalog.name.uppercased()).font(Theme.font(26, .black))
            Text(device.catalog.firmwareUpdateMode
                 ? "Em modo de atualização de firmware."
                 : "Detectado. Os controles deste aparelho ainda não são suportados.")
                .font(Theme.font(14)).foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

// MARK: - Ajustes

private struct SettingsPage: View {
    @Bindable var discord: DiscordCertifier
    let effects: AudioEffects
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("AJUSTES").font(Theme.font(26, .black)).tracking(1)
                Card("Geral") {
                    SettingRow(title: "Abrir no login",
                               detail: "Necessário para a Saída 7.1 tocar depois de reiniciar o Mac.") {
                        Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                            .onChange(of: launchAtLogin) { _, on in
                                do {
                                    if on { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
                Card("Discord") {
                    SettingRow(title: "Certificado no Discord", detail: discord.statusText) {
                        Toggle("", isOn: $discord.enabled).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                    }
                }
                if effects.surroundInstalled || effects.surroundNeedsUpdate {
                    Card("Saída 7.1") {
                        SettingRow(title: "Driver instalado",
                                   detail: "Remove a saída “LowerX 7.1” do Mac (pede a senha).") {
                            Button("Remover") { effects.installSurround(remove: true) }
                                .disabled(effects.installing)
                        }
                    }
                }
                Card("Sobre") {
                    Text("LowerX — controle não oficial do HyperX Cloud Stinger 2 Wireless para macOS, feito a partir do protocolo do NGENUITY. Não é afiliado à HyperX nem à HP. Imagens dos produtos: HyperX.")
                        .font(Theme.font(12)).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Textos de estado compartilhados com o painel da barra de menus

extension AudioEffects {
    var statusMessage: String? {
        switch state {
        case .active, .off: return nil
        case .stingerMissing: return "A Saída 7.1 toca no Stinger 2: conecte o receptor."
        case .waitingPermission: return "Aguardando a permissão de áudio do sistema…"
        case .denied: return "Permita “LowerX” em Ajustes › Privacidade › Gravação de tela e áudio do sistema."
        case .failed(let message): return "Falhou: \(message)"
        }
    }
}

extension DiscordCertifier {
    var statusText: String {
        guard enabled else { return "Desativado" }
        switch state {
        case .idle: return "Aguardando…"
        case .certified: return "Discord reconhece o headset"
        case .discordClosed: return "Discord fechado — aplica quando abrir"
        case .audioDeviceMissing: return "Headset não aparece como áudio"
        case .failed(let message): return "Falhou: \(message)"
        }
    }
}
