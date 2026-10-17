//
//  EventLogger.swift
//  HealthKitExample2
//
//  Append-only, hash-chained event log (JSONL, one file per day). Every entry
//  commits to the previous one, so deleting / editing / reordering lines is
//  detectable by the server when a session's log segment is uploaded.
//

import CryptoKit
import Foundation
import Combine
import os

nonisolated enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

nonisolated struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    var seq: Int
    var t: Date
    var monoNanos: UInt64
    var type: String
    var level: LogLevel
    var sessionId: UUID?
    var data: [String: String]
    var prevHash: String
    var hash: String
    var id: Int { seq }
}

nonisolated enum HashChain {
    static let genesis = String(repeating: "0", count: 64)

    static func digest(seq: Int, t: Date, monoNanos: UInt64, type: String, level: LogLevel,
                       sessionId: UUID?, data: [String: String], prevHash: String) -> String {
        let body = data.keys.sorted().map { "\($0)=\(data[$0] ?? "")" }.joined(separator: "&")
        let canonical = [String(seq), String(t.timeIntervalSince1970), String(monoNanos), type,
                         level.rawValue, sessionId?.uuidString ?? "-", body, prevHash].joined(separator: "|")
        return sha256Hex(Data(canonical.utf8))
    }

    static func make(seq: Int, t: Date, monoNanos: UInt64, type: String, level: LogLevel,
                     sessionId: UUID?, data: [String: String], prevHash: String) -> LogEntry {
        LogEntry(seq: seq, t: t, monoNanos: monoNanos, type: type, level: level, sessionId: sessionId, data: data,
                 prevHash: prevHash,
                 hash: digest(seq: seq, t: t, monoNanos: monoNanos, type: type, level: level,
                              sessionId: sessionId, data: data, prevHash: prevHash))
    }

    /// Returns the seq of the first broken entry, or nil when the chain is intact.
    static func firstBreak(in entries: [LogEntry]) -> Int? {
        var previous: LogEntry?
        for entry in entries {
            let recomputed = digest(seq: entry.seq, t: entry.t, monoNanos: entry.monoNanos, type: entry.type,
                                    level: entry.level, sessionId: entry.sessionId, data: entry.data,
                                    prevHash: entry.prevHash)
            if recomputed != entry.hash { return entry.seq }
            if let previous, entry.seq != previous.seq + 1 || entry.prevHash != previous.hash { return entry.seq }
            previous = entry
        }
        return nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class EventLogger: ObservableObject {
    static let shared = EventLogger(store: FileStore.app.sub("logs"))

    @Published private(set) var recent: [LogEntry] = []
    @Published private(set) var chainIntact = true
    private var headSeq = 0
    private var headHash = HashChain.genesis
    private let store: FileStore
    private let osLog = Logger(subsystem: "com.sixpilot.HealthKitExample", category: "events")
    private let recentLimit = 800

    nonisolated private struct Head: Codable { var seq: Int; var hash: String }

    init(store: FileStore) {
        self.store = store
        if let head = try? store.load(Head.self, from: "head.json") {
            headSeq = head.seq
            headHash = head.hash
        }
        let today = loadEntries(file: Self.fileName(for: Date()))
        recent = Array(today.suffix(recentLimit))
        if let last = allEntries().last, last.seq != headSeq || last.hash != headHash {
            chainIntact = false
        } else if HashChain.firstBreak(in: today) != nil {
            chainIntact = false
        }
        if !chainIntact {
            log("logIntegrityBroken", level: .error, ["headSeq": String(headSeq)])
        }
    }

    var nextSeq: Int { headSeq + 1 }

    @discardableResult
    func log(_ type: String, level: LogLevel = .info, session: UUID? = nil, _ data: [String: String] = [:]) -> LogEntry {
        let entry = HashChain.make(seq: headSeq + 1, t: Date(), monoNanos: ClockGuard.monotonicNanos(), type: type,
                                   level: level, sessionId: session, data: data, prevHash: headHash)
        headSeq = entry.seq
        headHash = entry.hash
        if let line = try? FileStore.encoder.encode(entry) {
            try? store.append(line: line, to: Self.fileName(for: entry.t))
        }
        try? store.save(Head(seq: headSeq, hash: headHash), to: "head.json")
        recent.append(entry)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        let summary = data.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        osLog.log("[\(entry.seq)] \(type, privacy: .public) \(summary, privacy: .public)")
        return entry
    }

    /// Contiguous chain segment, used as tamper evidence inside a session report.
    func entries(fromSeq: Int, toSeq: Int) -> [LogEntry] {
        allEntries().filter { $0.seq >= fromSeq && $0.seq <= toSeq }
    }

    func allEntries() -> [LogEntry] {
        store.list().filter { $0.hasPrefix("events-") }.flatMap { loadEntries(file: $0) }
    }

    func exportFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("move2earn-events.jsonl")
        var data = Data()
        for name in store.list() where name.hasPrefix("events-") {
            if let chunk = store.read(name) { data.append(chunk) }
        }
        try? data.write(to: url, options: .atomic)
        return url
    }

    func verifyAll() -> Int? {
        let all = allEntries()
        let broken = HashChain.firstBreak(in: all)
        chainIntact = broken == nil
        return broken
    }

    private func loadEntries(file: String) -> [LogEntry] {
        guard let data = store.read(file), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? FileStore.decoder.decode(LogEntry.self, from: Data($0.utf8))
        }
    }

    private static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "events-\(f.string(from: date)).jsonl"
    }
}
