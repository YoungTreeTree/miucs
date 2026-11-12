import Darwin
import XCTest
@testable import MiucsCore

final class HardwareIOTests: XCTestCase {
    func testMultiplexesReadWriteAndEOFWithHighDescriptors() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let reader = fcntl(pair[0], F_DUPFD, 96)
        XCTAssertGreaterThanOrEqual(reader, 96)
        close(pair[0])
        var writer = pair[1]
        defer { close(reader); if writer >= 0 { close(writer) } }
        var descriptors = [pollfd(fd: reader, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: writer, events: Int16(POLLOUT), revents: 0),
                           pollfd(fd: -1, events: Int16(POLLIN), revents: 0)]
        XCTAssertEqual(HardwareIO.wait(&descriptors, milliseconds: 0), 1)
        XCTAssertEqual(descriptors[0].revents, 0)
        XCTAssertEqual(descriptors[1].revents, Int16(POLLOUT))
        var byte: UInt8 = 42
        XCTAssertEqual(write(writer, &byte, 1), 1)
        XCTAssertEqual(HardwareIO.wait(&descriptors, milliseconds: 20), 2)
        XCTAssertEqual(descriptors[0].revents, Int16(POLLIN))
        XCTAssertEqual(read(reader, &byte, 1), 1)
        XCTAssertEqual(byte, 42)
        descriptors.removeLast(2)
        XCTAssertEqual(HardwareIO.wait(&descriptors, milliseconds: 10), 0)
        close(writer); writer = -1
        XCTAssertEqual(HardwareIO.wait(&descriptors, milliseconds: 20), 1)
        XCTAssertEqual(read(reader, &byte, 1), 0, "EOF must wake the transport instead of spinning")
    }

    func testRejectsOutOfBoundsDescriptors() {
        var descriptors = [pollfd(fd: FD_SETSIZE, events: Int16(POLLIN), revents: 0)]
        XCTAssertEqual(HardwareIO.wait(&descriptors, milliseconds: 0), -1)
        XCTAssertEqual(errno, EINVAL)
    }
}
