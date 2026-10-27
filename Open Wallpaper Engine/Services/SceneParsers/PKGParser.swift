//
//  PKGParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine PKGV archive files.
//  Format: length-prefixed "PKGVxxxx" header, entry count,
//  then per entry: length-prefixed path + offset + length.
//  File data follows contiguously after the header table.
//

import Foundation

struct PKGEntry {
    let path: String
    let offset: UInt32
    let length: UInt32
}

class PKGParser {
    private let data: Data
    private let entries: [PKGEntry]
    /// Entries by path, for `extractFile`. A scene resolves every model, material and texture
    /// through it, and each lookup used to scan the whole table.
    /// Where a path repeats, the first entry wins, as `first(where:)` had it.
    private let entryByPath: [String: PKGEntry]
    /// Where the file data starts, relative to `data.startIndex`.
    private let dataBaseOffset: Int

    /// `data` is read in place. It used to be copied into a `[UInt8]` first, for "safe, aligned
    /// reads", which made every scene pay for its whole archive a second time just to read the
    /// table at the front of it: the largest in the library, Three-Body's 151 MB `scene.pkg`,
    /// peaked at 319 MB to open. Unaligned little-endian loads straight off the mapped buffer do
    /// the same job, and opening it now peaks at 2 MB.
    init(data: Data) throws {
        self.data = data

        var parsedEntries: [PKGEntry] = []
        let tableEnd: Int = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            var cursor = 0

            func readUInt32() throws -> UInt32 {
                guard cursor + 4 <= bytes.count else {
                    throw PKGError.unexpectedEndOfFile
                }
                let value = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor,
                                                                     as: UInt32.self))
                cursor += 4
                return value
            }

            func readString(length: Int) throws -> String {
                guard length >= 0, cursor + length <= bytes.count else {
                    throw PKGError.unexpectedEndOfFile
                }
                let slice = UnsafeRawBufferPointer(rebasing: bytes[cursor..<cursor+length])
                cursor += length
                return String(bytes: slice, encoding: .utf8)
                    ?? String(bytes: slice, encoding: .isoLatin1)
                    ?? ""
            }

            // Read header string (e.g. "PKGV0013")
            let headerLen = try readUInt32()
            guard headerLen < 100 else { throw PKGError.invalidMagic("(header too long: \(headerLen))") }
            let header = try readString(length: Int(headerLen))
            guard header.hasPrefix("PKGV") else {
                throw PKGError.invalidMagic(header)
            }

            // Read entry count
            let entryCount = try readUInt32()
            guard entryCount < 100_000 else { throw PKGError.unexpectedEndOfFile }

            // Read file table
            parsedEntries.reserveCapacity(Int(entryCount))
            for _ in 0..<entryCount {
                let pathLen = try readUInt32()
                guard pathLen < 10_000 else { throw PKGError.unexpectedEndOfFile }
                let path = try readString(length: Int(pathLen))
                let offset = try readUInt32()
                let length = try readUInt32()
                parsedEntries.append(PKGEntry(path: path, offset: offset, length: length))
            }
            return cursor
        }

        self.entries = parsedEntries
        self.entryByPath = Dictionary(parsedEntries.map { ($0.path, $0) },
                                      uniquingKeysWith: { first, _ in first })
        self.dataBaseOffset = tableEnd
    }

    /// Mapped rather than read, as `SceneSoundscape` already opens the same file. An extracted
    /// entry is a slice of `data`, so only the pages a scene actually touches are read in, and
    /// they are clean, file-backed pages the system can reclaim rather than 151 MB of heap.
    convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data)
    }

    var fileList: [String] {
        entries.map(\.path)
    }

    func extractFile(named name: String) -> Data? {
        guard let entry = entryByPath[name] else {
            return nil
        }
        let start = dataBaseOffset + Int(entry.offset)
        let end = start + Int(entry.length)
        guard end <= data.count else { return nil }
        // Offsets are relative to the buffer, and `data` may be a slice that does not start at 0.
        return data[(data.startIndex + start)..<(data.startIndex + end)]
    }

    /// `decoder` is the caller's so it can carry `userInfo` — the scene file is decoded with the
    /// wallpaper's `SceneUserProperties` attached.
    func extractJSON<T: Decodable>(named name: String, as type: T.Type,
                                   decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        guard let fileData = extractFile(named: name) else { return nil }
        return try decoder.decode(type, from: fileData)
    }
}

enum PKGError: Error, LocalizedError {
    case invalidMagic(String)
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .invalidMagic(let got):
            return "Invalid PKG header: expected PKGV*, got '\(got)'"
        case .unexpectedEndOfFile:
            return "Unexpected end of PKG file"
        }
    }
}
