import Darwin
import Foundation

/// A TCP port in LISTEN state and the process holding it.
struct ListeningSocket {
    let port: Int
    let pid: pid_t
    let command: String
    var addresses: [String]
}

struct SocketScan {
    var listening: [ListeningSocket] = []
    /// Inbound established connections, keyed by local port.
    var inboundConnections: [Int: Int] = [:]
}

/// Reads TCP sockets straight from each process's file descriptors through
/// libproc, rather than launching `lsof` on every scan. Like `lsof` without
/// root, it sees only the current user's processes.
enum SocketScanner {
    static func scan() -> SocketScan {
        var result = SocketScan()
        var byPort: [Int: ListeningSocket] = [:]

        // Ascending pids, so a socket shared after fork belongs to the parent, as with lsof.
        for pid in allPids().sorted() {
            var command: String?
            for socket in tcpSockets(of: pid) {
                switch Int32(socket.state) {
                case TSI_S_LISTEN:
                    let name = command ?? processName(pid)
                    command = name
                    if var existing = byPort[socket.port] {
                        if existing.pid == pid, !existing.addresses.contains(socket.address) {
                            existing.addresses.append(socket.address)
                            byPort[socket.port] = existing
                        }
                    } else {
                        byPort[socket.port] = ListeningSocket(port: socket.port, pid: pid, command: name, addresses: [socket.address])
                    }
                case TSI_S_ESTABLISHED:
                    result.inboundConnections[socket.port, default: 0] += 1
                default:
                    break
                }
            }
        }

        result.listening = byPort.values.sorted { $0.port < $1.port }
        return result
    }

    private struct TCPSocket {
        let port: Int
        let state: Int32
        let address: String
    }

    private static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    private static func tcpSockets(of pid: pid_t) -> [TCPSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Leave room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }

        var sockets: [TCPSocket] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: local.insi_lport)))
            sockets.append(TCPSocket(port: port, state: tcp.tcpsi_state, address: address(of: local)))
        }
        return sockets
    }

    /// The local address as lsof prints it: `127.0.0.1`, `[::1]`, or `*` for any.
    private static func address(of socket: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
            var address = socket.insi_laddr.ina_46.i46a_addr4
            if address.s_addr == INADDR_ANY { return "*" }
            inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
            return String(cString: buffer)
        }
        var address = socket.insi_laddr.ina_6
        if withUnsafeBytes(of: &address, { $0.allSatisfy { $0 == 0 } }) { return "*" }
        inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        return "[\(String(cString: buffer))]"
    }

    /// The name lsof reports: the process name, which unlike `comm` isn't cut at 16 characters.
    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}
