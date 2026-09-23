// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Darwin
import Foundation

/// One command name, resolved the way the shell resolves it: the first match
/// in PATH wins and later ones are shadowed.
struct EnvironmentTool: Identifiable, Equatable {
    let command: String
    let path: String?
    let version: String?
    /// Set when the winning file runs something other than the tool it is
    /// named after (a symlink to another name, or a script that execs one).
    let shimTarget: String?
    let shadowedPaths: [String]
    let source: String?
    var id: String { command }
}

struct EnvironmentReport {
    var terminalPath: [String] = []
    var appPath: [String] = []
    var tools: [EnvironmentTool] = []
    /// False when the login shell did not answer and `terminalPath` holds only
    /// the system entries from /etc/paths.
    var readLoginShell = false

    /// Directories a terminal has and an app opened from Finder or the Dock
    /// does not, in terminal order.
    var terminalOnlyPath: [String] {
        let app = Set(appPath)
        return terminalPath.filter { !app.contains($0) }
    }
}

/// Read-only: every check runs a bounded child process or reads a file, and
/// nothing here writes a file or changes an environment.
enum EnvironmentSupport {
    /// `npx` and `bunx` are on the list because pasted MCP configs run them.
    static let commands = ["node", "npm", "npx", "bun", "bunx", "python3", "uv"]

    /// What launchd hands a process when nothing set PATH for it, which is
    /// what apps opened from Finder or the Dock inherit.
    static let launchdDefaultPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private static let marker = "__VORSSAINT_PATH__"
    private static let commandTimeout: TimeInterval = 5
    private static let shellTimeout: TimeInterval = 10
    private static let maxOutputBytes = 64 * 1024

    static func inspect(cancellation: BoundedProcessCancellation? = nil) -> EnvironmentReport {
        var report = EnvironmentReport()
        let shellPath = loginShellPath(cancellation: cancellation)
        report.readLoginShell = shellPath != nil
        report.terminalPath = shellPath ?? systemPath()
        report.appPath = appPath(cancellation: cancellation)
        for command in commands where cancellation?.isCancelled != true {
            report.tools.append(tool(named: command, in: report.terminalPath,
                                     cancellation: cancellation))
        }
        return report
    }

    /// Asks the user's own shell for its PATH, since only the shell's startup
    /// files know it. Interactive as well as login, because a Terminal window
    /// is both and installers such as bun, nvm and conda edit ~/.zshrc, which
    /// zsh reads only for interactive shells. The markers keep anything those
    /// files print out of the answer.
    static func loginShellPath(cancellation: BoundedProcessCancellation? = nil) -> [String]? {
        guard let pw = getpwuid(getuid()), let raw = pw.pointee.pw_shell else { return nil }
        let shell = String(cString: raw)
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let script = "printf '\(marker)%s\(marker)' \"$PATH\""
        for arguments in [["-l", "-i", "-c", script], ["-l", "-c", script]] {
            let result = BoundedProcessRunner.run(shell, arguments,
                                                  timeout: shellTimeout,
                                                  maxOutputBytes: maxOutputBytes,
                                                  cancellation: cancellation)
            let parts = String(decoding: result.output, as: UTF8.self).components(separatedBy: marker)
            guard result.status == 0, parts.count >= 3 else { continue }
            let entries = splitPath(parts[parts.count - 2])
            if !entries.isEmpty { return entries }
        }
        return nil
    }

    static func systemPath() -> [String] {
        let fragments = ((try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d")) ?? [])
            .sorted().map { "/etc/paths.d/" + $0 }
        let lines = (["/etc/paths"] + fragments)
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(whereSeparator: \.isNewline)
        return splitPath(lines.joined(separator: ":"))
    }

    /// `launchctl getenv PATH` is normally empty, and then launchd's default
    /// is the answer rather than this process's PATH, which depends on how
    /// the app itself was started.
    static func appPath(cancellation: BoundedProcessCancellation? = nil) -> [String] {
        let result = BoundedProcessRunner.run("/bin/launchctl", ["getenv", "PATH"],
                                              timeout: commandTimeout,
                                              maxOutputBytes: maxOutputBytes,
                                              cancellation: cancellation)
        let entries = result.status == 0
            ? splitPath(String(decoding: result.output, as: UTF8.self)) : []
        return entries.isEmpty ? launchdDefaultPath : entries
    }

    static func tool(named command: String, in path: [String],
                     cancellation: BoundedProcessCancellation? = nil) -> EnvironmentTool {
        let matches = splitPath(path.map { ($0 as NSString).appendingPathComponent(command) }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .joined(separator: ":"))
        guard let winner = matches.first else {
            return EnvironmentTool(command: command, path: nil, version: nil, shimTarget: nil,
                                   shadowedPaths: [], source: nil)
        }
        // `npm` and `npx` start with `#!/usr/bin/env node`, so the version
        // check needs the terminal's PATH rather than this app's.
        let result = BoundedProcessRunner.run("/usr/bin/env",
                                              ["PATH=" + path.joined(separator: ":"), winner, "--version"],
                                              timeout: commandTimeout,
                                              maxOutputBytes: maxOutputBytes,
                                              cancellation: cancellation)
        // A wrapper that refuses `--version` exits non-zero with a complaint
        // that is not a version.
        let firstLine = String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let resolved = URL(fileURLWithPath: winner).resolvingSymlinksInPath().path
        return EnvironmentTool(command: command,
                               path: winner,
                               version: result.status == 0 && firstLine?.isEmpty == false ? firstLine : nil,
                               shimTarget: shimTarget(of: winner, command: command),
                               shadowedPaths: Array(matches.dropFirst()),
                               source: source(of: winner, resolvedPath: resolved, home: NSHomeDirectory()))
    }

    /// A symlink names its target directly; a wrapper script names it on its
    /// `exec` line.
    static func shimTarget(of path: String, command: String) -> String? {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let resolved = destination.hasPrefix("/")
                ? destination
                : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
            let target = (resolved as NSString).standardizingPath
            return (target as NSString).lastPathComponent == command ? nil : target
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        let head = (try? handle.read(upToCount: 8 * 1024)) ?? Data()
        try? handle.close()
        guard let text = String(data: head, encoding: .utf8), text.hasPrefix("#!") else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let target = execTarget(in: String(line)) else { continue }
            let name = (target as NSString).lastPathComponent
            if !name.isEmpty, name != command, name != "env" { return target }
        }
        return nil
    }

    /// The first thing an `exec` on this line hands control to, unquoted.
    /// `exec` is not always the first word: a case branch reads
    /// `install|i) exec "$HOME/.bun/bin/bun" install "$@" ;;`.
    static func execTarget(in line: String) -> String? {
        var search = line.startIndex..<line.endIndex
        while let found = line.range(of: "exec ", range: search) {
            search = found.upperBound..<line.endIndex
            if found.lowerBound != line.startIndex,
               !" \t;&|)".contains(line[line.index(before: found.lowerBound)]) { continue }
            var skipNext = false
            for word in line[found.upperBound...].split(separator: " ") {
                if skipNext { skipNext = false; continue }
                // `exec -a NAME cmd` renames the process; NAME is not the target.
                if word == "-a" { skipNext = true; continue }
                if word.hasPrefix("-") { continue }
                let target = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !target.isEmpty { return target }
                break
            }
        }
        return nil
    }

    /// Who installed the file, when a path or a marker file says so. Names
    /// are proper nouns and stay untranslated.
    static func source(of path: String, resolvedPath: String, home: String) -> String? {
        let paths = [path, resolvedPath]
        for location in paths {
            let root = ((location as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: root + "/conda-meta") { return "Conda" }
            if FileManager.default.fileExists(atPath: root + "/pyvenv.cfg") { return "venv" }
        }
        if paths.contains(where: { $0.hasPrefix("/usr/bin/") || $0.hasPrefix("/System/") }) {
            return "macOS"
        }
        let managers = [
            ("mise", [home + "/.local/share/mise"]), ("asdf", [home + "/.asdf"]),
            ("nvm", [home + "/.nvm"]), ("fnm", [home + "/.local/share/fnm"]),
            ("Volta", [home + "/.volta"]), ("pyenv", [home + "/.pyenv"]), ("Bun", [home + "/.bun"]),
            ("Conda", [home + "/miniforge3", home + "/miniconda3", home + "/anaconda3"]),
            ("Homebrew", ["/opt/homebrew/Cellar", "/usr/local/Cellar"]),
        ]
        for (manager, roots) in managers
        where roots.contains(where: { root in paths.contains { $0.hasPrefix(root + "/") } }) {
            return manager
        }
        return nil
    }

    /// Plain English text for a bug report, in the order the page shows it.
    static func reportText(_ report: EnvironmentReport) -> String {
        var lines = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "", "commands"]
        for tool in report.tools {
            guard let path = tool.path else {
                lines.append("  \(tool.command): not found")
                continue
            }
            var line = "  \(tool.command): \(path)"
            if let version = tool.version { line += "  [\(version)]" }
            if let source = tool.source { line += "  (\(source))" }
            if let shim = tool.shimTarget { line += "  -> \(shim)" }
            lines.append(line)
            lines += tool.shadowedPaths.map { "    shadowed: \($0)" }
        }
        lines += ["", "terminal PATH" + (report.readLoginShell ? "" : " (login shell did not answer; system entries only)")]
        lines += report.terminalPath.map { "  " + $0 }
        lines += ["", "app PATH"] + report.appPath.map { "  " + $0 }
        lines += ["", "in terminal but not in apps"]
        let missing = report.terminalOnlyPath
        lines += missing.isEmpty ? ["  (none)"] : missing.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    /// Splits a colon list, dropping empty entries and later repeats.
    static func splitPath(_ value: String) -> [String] {
        var seen: Set<String> = []
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }
}

/// Reads the environment on demand for the Settings page; nothing runs while
/// the page is closed.
final class EnvironmentService: ObservableObject {
    static let shared = EnvironmentService()
    @Published private(set) var report: EnvironmentReport?
    @Published private(set) var isRefreshing = false
    private var cancellation: BoundedProcessCancellation?

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let cancellation = BoundedProcessCancellation()
        self.cancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async {
            let report = EnvironmentSupport.inspect(cancellation: cancellation)
            DispatchQueue.main.async {
                guard self.cancellation === cancellation else { return }
                self.cancellation = nil
                self.report = report
                self.isRefreshing = false
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        isRefreshing = false
    }
}
