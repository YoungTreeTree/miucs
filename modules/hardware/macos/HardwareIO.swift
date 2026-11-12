import Darwin

/// Darwin's poll(2) does not support device files reliably. Use select(2) for
/// the small sets of serial/socket descriptors used by the hardware transports.
public enum HardwareIO {
    public static func wait(_ descriptors: inout [pollfd], milliseconds: Int32) -> Int32 {
        guard milliseconds >= 0 else { errno = EINVAL; return -1 }
        var reads = fd_set(), writes = fd_set(), errors = fd_set()
        var highest: Int32 = -1
        for index in descriptors.indices {
            descriptors[index].revents = 0
            let descriptor = descriptors[index]
            guard descriptor.fd >= 0 else { continue }
            guard descriptor.fd < FD_SETSIZE else { errno = EINVAL; return -1 }
            highest = max(highest, descriptor.fd)
            if descriptor.events & Int16(POLLIN) != 0 { insert(descriptor.fd, into: &reads) }
            if descriptor.events & Int16(POLLOUT) != 0 { insert(descriptor.fd, into: &writes) }
            insert(descriptor.fd, into: &errors)
        }
        var timeout = timeval(tv_sec: Int(milliseconds / 1000), tv_usec: Int32(milliseconds % 1000) * 1000)
        let ready = select(highest + 1, &reads, &writes, &errors, &timeout)
        guard ready > 0 else { return ready }
        var count: Int32 = 0
        for index in descriptors.indices where descriptors[index].fd >= 0 {
            let fd = descriptors[index].fd
            if contains(fd, in: &reads) { descriptors[index].revents |= Int16(POLLIN) }
            if contains(fd, in: &writes) { descriptors[index].revents |= Int16(POLLOUT) }
            if contains(fd, in: &errors) { descriptors[index].revents |= Int16(POLLERR) }
            if descriptors[index].revents != 0 { count += 1 }
        }
        return count
    }

    // FD_SET/FD_ISSET are C macros. Darwin fd_set consists of 32-bit masks.
    private static func insert(_ fd: Int32, into set: inout fd_set) {
        withUnsafeMutableBytes(of: &set) {
            $0.bindMemory(to: UInt32.self)[Int(fd) / 32] |= UInt32(1) << (UInt32(fd) % 32)
        }
    }
    private static func contains(_ fd: Int32, in set: inout fd_set) -> Bool {
        withUnsafeBytes(of: &set) {
            $0.bindMemory(to: UInt32.self)[Int(fd) / 32] & (UInt32(1) << (UInt32(fd) % 32)) != 0
        }
    }
}
