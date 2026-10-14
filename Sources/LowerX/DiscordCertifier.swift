import AppKit
import Foundation
import Observation

/// Marca o headset como "certified" no Discord, como o NGENUITY faz no Windows
/// (`DiscordService.SendCertifiedDeviceNotificationAsync`): um POST para o RPC local do
/// Discord com `SET_CERTIFIED_DEVICES`. O Discord esquece a certificação ao reiniciar,
/// então ela é reenviada quando o Discord abre e quando o headset conecta.
@Observable
@MainActor
final class DiscordCertifier {
    enum State: Equatable {
        case idle
        case discordClosed
        case audioDeviceMissing
        case certified
        case failed(String)
    }

    private(set) var state: State = .idle

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { certify() }
        }
    }

    private static let enabledKey = "discordCertify"
    // Mesmos valores do NGENUITY 2.38: client_id da HyperX autorizado pelo Discord,
    // faixa de portas do RPC local e as capacidades declaradas do headset.
    private static let clientID = "654869547178000385"
    private static let ports = 6463...6472
    private static let productURL = "https://support.hyperx.com/Headsets/Cloud-Stinger-2-Wireless/"
    private nonisolated static let discordBundleIDs: Set<String> = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]

    @ObservationIgnored private var lastPort: Int?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var retriesLeft = 0
    @ObservationIgnored private var launchObserver: NSObjectProtocol?

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, Self.discordBundleIDs.contains(id) else { return }
            // O RPC do Discord leva alguns segundos para subir depois do launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                MainActor.assumeIsolated { self?.certify() }
            }
        }
    }

    func certify() {
        retriesLeft = 3
        attempt()
    }

    // MARK: - Interno

    /// Um pedido por vez: o RPC do Discord para de responder se for bombardeado.
    private func attempt() {
        guard enabled, !inFlight else { return }
        guard let uid = AudioDevices.stingerUID() else {
            state = .audioDeviceMissing
            return
        }
        inFlight = true
        let body = Self.requestBody(uid: uid)
        Task {
            let result = await Self.post(body, preferredPort: lastPort)
            inFlight = false
            switch result {
            case .success(let port):
                lastPort = port
                state = .certified
            case .failure(let error as URLError) where error.code == .timedOut:
                // Discord aberto mas ocupado: tenta de novo daqui a pouco.
                state = .failed("Discord não respondeu")
                scheduleRetry()
            case .failure(let error as URLError):
                lastPort = nil
                state = error.code == .cannotConnectToHost ? .discordClosed : .failed(error.localizedDescription)
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleRetry() {
        guard retriesLeft > 0 else { return }
        retriesLeft -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { self?.attempt() }
        }
    }

    private static func post(_ body: Data, preferredPort: Int?) async -> Result<Int, Error> {
        let order = preferredPort.map { [$0] + ports.filter { $0 != preferredPort } } ?? Array(ports)
        var lastError: Error = URLError(.cannotConnectToHost)
        for port in order {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/rpc?v=1&client_id=\(clientID)")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 10
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    lastError = NSError(domain: "Discord", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                        userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
                    continue
                }
                return .success(port)
            } catch let error as URLError where error.code == .timedOut {
                // Algo escuta nesta porta mas não respondeu: não adianta varrer as outras.
                return .failure(error)
            } catch {
                lastError = error
            }
        }
        return .failure(lastError)
    }

    private static func requestBody(uid: String) -> Data {
        func device(_ type: String) -> [String: Any] {
            [
                "type": type,
                "id": uid,
                "vendor": ["name": "HyperX", "url": "https://www.hyperxgaming.com/"],
                "model": ["name": "Cloud Stinger 2 Wireless", "url": productURL],
                "related": [uid],
                "echo_cancellation": false,
                "noise_suppression": false,
                "automatic_gain_control": true,
                "hardware_mute": false,
            ]
        }
        let payload: [String: Any] = [
            "nonce": UUID().uuidString,
            "cmd": "SET_CERTIFIED_DEVICES",
            "args": ["devices": [device("audiooutput"), device("audioinput")]],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
