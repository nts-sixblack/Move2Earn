//
//  FileStore.swift
//  HealthKitExample2
//
//  Atomic JSON persistence in Application Support. Files use
//  `completeUntilFirstUserAuthentication` so they can still be written while
//  the app runs in the background with the device locked.
//

import Foundation

nonisolated struct FileStore: Sendable {
    let baseURL: URL

    static let app: FileStore = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoveToEarn", isDirectory: true)
        return FileStore(baseURL: url)
    }()

    static func temporary() -> FileStore {
        FileStore(baseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("m2e-\(UUID().uuidString)", isDirectory: true))
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var prettyEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { baseURL.appendingPathComponent(name) }

    func sub(_ name: String) -> FileStore { FileStore(baseURL: url(name)) }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    func save<T: Encodable>(_ value: T, to name: String) throws {
        try write(FileStore.encoder.encode(value), to: name)
    }

    func write(_ data: Data, to name: String) throws {
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try FileStore.decoder.decode(type, from: Data(contentsOf: url(name)))
    }

    func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    func append(line: Data, to name: String) throws {
        let fileURL = url(name)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = line
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    func delete(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)) ?? []).sorted()
    }

    func wipe() {
        try? FileManager.default.removeItem(at: baseURL)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
}
