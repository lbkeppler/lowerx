import Foundation
import IOKit
import IOKit.usb
import Observation

/// Lista os aparelhos HyperX conectados por USB, identificados pelo `DeviceCatalog`.
/// Observa o registro do IOKit (sem abrir os aparelhos), então não exige a permissão
/// de Monitoramento de Entrada mesmo para teclados e mouses.
@Observable
@MainActor
final class USBDeviceWatcher {
    struct Device: Identifiable, Equatable {
        /// `locationID` do USB: distingue dois aparelhos iguais conectados.
        let id: UInt32
        let catalog: DeviceCatalog.Entry

        static func == (a: Device, b: Device) -> Bool { a.id == b.id }
    }

    private(set) var devices: [Device] = []

    @ObservationIgnored private var port: IONotificationPortRef?
    @ObservationIgnored private var iterators: [io_iterator_t] = []

    init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for vendorID in DeviceCatalog.vendorIDs {
            for (type, callback) in [(kIOFirstMatchNotification, Self.added), (kIOTerminatedNotification, Self.removed)] {
                let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
                // O casamento USB do IOKit não aceita idVendor sozinho; IOPropertyMatch
                // compara a propriedade diretamente.
                matching[kIOPropertyMatchKey] = [kUSBVendorID: vendorID]
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, type, matching, callback, ctx, &iterator) == KERN_SUCCESS
                else { continue }
                iterators.append(iterator)
                // Esvaziar o iterador arma a notificação e trata os já conectados.
                callback(ctx, iterator)
            }
        }
    }

    private static let added: IOServiceMatchingCallback = { ctx, iterator in
        let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue()
        MainActor.assumeIsolated {
            forEach(iterator) { service in
                guard let device = device(for: service), !watcher.devices.contains(device) else { return }
                watcher.devices.append(device)
            }
            watcher.devices.sort { $0.catalog.name < $1.catalog.name }
        }
    }

    private static let removed: IOServiceMatchingCallback = { ctx, iterator in
        let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue()
        MainActor.assumeIsolated {
            forEach(iterator) { service in
                guard let location = intProperty(service, kUSBDevicePropertyLocationID) else { return }
                watcher.devices.removeAll { $0.id == UInt32(location) }
            }
        }
    }

    private static func forEach(_ iterator: io_iterator_t, _ body: (io_service_t) -> Void) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func device(for service: io_service_t) -> Device? {
        guard let vendor = intProperty(service, kUSBVendorID),
              let product = intProperty(service, kUSBProductID),
              let location = intProperty(service, kUSBDevicePropertyLocationID),
              let entry = DeviceCatalog.entry(vendorID: vendor, productID: product) else { return nil }
        return Device(id: UInt32(location), catalog: entry)
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
}
