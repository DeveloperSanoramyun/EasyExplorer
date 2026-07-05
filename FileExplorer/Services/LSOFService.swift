//
//  LSOFService.swift
//  FileExplorer
//
//  Runs `/usr/sbin/lsof` against a single file to find which processes
//  have it open. Surfaced from the Properties dialog and from error
//  recovery when copy/move/trash fails with "file in use".
//

import Foundation

enum LSOFService {

    struct Holder: Identifiable, Hashable {
        let id = UUID()
        let command: String
        let pid: Int32
        let user: String
    }

    /// Asks lsof which processes currently have `url` open. Returns an
    /// empty list when nothing has it or lsof itself failed. Throws
    /// nothing — we treat "couldn't tell" as "nothing holding it".
    /// Synchronous; callers run it from a background Task.
    static func holders(of url: URL) -> [Holder] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -F pcLu: machine-readable output with fields p(pid), c(command),
        //          L(login user), u(uid).
        process.arguments = ["-F", "pcL", url.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseLSOFOutput(text)
    }

    /// lsof -F output format: lines prefixed `p<pid>`, `c<command>`,
    /// `L<user>`. Each process block starts with `p<pid>`.
    private static func parseLSOFOutput(_ text: String) -> [Holder] {
        var holders: [Holder] = []
        var pid: Int32? = nil
        var cmd: String = ""
        var user: String = ""
        for line in text.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                // New process block — flush previous if complete.
                if let p = pid {
                    holders.append(Holder(command: cmd, pid: p, user: user))
                }
                pid = Int32(value)
                cmd = ""
                user = ""
            case "c":
                cmd = value
            case "L":
                user = value
            default:
                break
            }
        }
        if let p = pid {
            holders.append(Holder(command: cmd, pid: p, user: user))
        }
        return holders
    }

}
