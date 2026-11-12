import Foundation
import Darwin
import IOKit
import IOKit.serial

struct HardwarePort: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    static var deskIsleRelayPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.deskisle.layout/uart/animation.sock").path
    }

    static func connected() -> [HardwarePort] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports = [HardwarePort]()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            func parentProperty(_ key: String) -> CFTypeRef? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let name = parentProperty("USB Product Name") as? String ?? ""
            if name == "DeskIsle" {
                let interface = (parentProperty("bInterfaceNumber") as? NSNumber)?.intValue
                let interfaceName = parentProperty("USB Interface Name") as? String
                guard interface != 2, interface != 3, interfaceName != "DeskIsle Layout" else { continue }
            }
            if name == "Miucs P4 Display" || name == "DeskIsle" { ports.append(HardwarePort(path: path, name: name)) }
        }
        let relay = deskIsleRelayPath
        var info = stat()
        if ports.isEmpty, lstat(relay, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() {
            ports.append(HardwarePort(path: relay, name: "DeskIsle"))
        }
        return ports.sorted { $0.path < $1.path }
    }
}
