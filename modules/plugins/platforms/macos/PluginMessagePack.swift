import Foundation

/// Small binary boundary encoder. No JSON text or per-frame intermediate serialization.
enum PluginMessagePack {
    static func encode(_ value: Any) -> Data {
        var data = Data()
        func integer(_ value: UInt64, _ bytes: Int) {
            for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func append(_ value: Any) {
            switch value {
            case is NSNull: data.append(0xc0)
            case let value as Bool: data.append(value ? 0xc3 : 0xc2)
            case let value as String:
                let bytes = Array(value.utf8)
                data.append(0xdb); integer(UInt64(bytes.count), 4); data.append(contentsOf: bytes)
            case let value as UInt64: data.append(0xcf); integer(value, 8)
            case let value as UInt8: data.append(0xcc); data.append(value)
            case let value as UInt16: data.append(0xcd); integer(UInt64(value), 2)
            case let value as Int: data.append(0xd3); integer(UInt64(bitPattern: Int64(value)), 8)
            case let value as Double: data.append(0xcb); integer(value.isFinite ? value.bitPattern : 0, 8)
            case let value as Float: data.append(0xcb); integer(Double(value).bitPattern, 8)
            case let value as [String: Any]:
                data.append(0xdf); integer(UInt64(value.count), 4)
                for key in value.keys.sorted() { append(key); append(value[key]!) }
            case let value as [Any]:
                data.append(0xdd); integer(UInt64(value.count), 4)
                for item in value { append(item) }
            default: preconditionFailure("Unsupported plugin boundary value: \(type(of: value))")
            }
        }
        append(value); return data
    }
}
