import Foundation
import IOKit.hid

/// Acesso à coleção vendor do dongle via IOHIDManager. Detecta conexão/desconexão
/// do dongle, envia output reports e entrega input reports no main run loop.
final class HIDTransport {
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?
    var onReport: (([UInt8]) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    var isAttached: Bool { device != nil }

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Stinger.vendorID,
            kIOHIDProductIDKey: Stinger.productID,
            kIOHIDDeviceUsagePageKey: Stinger.usagePage,
            kIOHIDDeviceUsageKey: Stinger.usage,
        ] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    @discardableResult
    func send(_ report: [UInt8]) -> Bool {
        guard let device else { return false }
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]),
                                    report, report.count) == kIOReturnSuccess
    }

    private func attach(_ dev: IOHIDDevice) {
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, 64, { ctx, _, _, _, _, bytes, len in
            let report = Array(UnsafeBufferPointer(start: bytes, count: len))
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().onReport?(report)
        }, ctx)
        onAttach?()
    }

    private func detach(_ dev: IOHIDDevice) {
        guard dev == device else { return }
        device = nil
        onDetach?()
    }
}
