//
//  TextLineReader.swift
//  OsaurusStatsPack
//

import Foundation

enum TextLineReader {
    static func forEachLine(at url: URL, _ body: (String, Int) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        var lineNumber = 1

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                var lineData = buffer[..<newline]
                if lineData.last == 0x0D {
                    lineData = lineData.dropLast()
                }
                guard let line = String(data: Data(lineData), encoding: .utf8) else {
                    throw StatsPackError.unreadableUTF8Line(line: lineNumber)
                }
                try body(line, lineNumber)
                lineNumber += 1
                buffer.removeSubrange(buffer.startIndex ... newline)
            }
        }

        if !buffer.isEmpty {
            if buffer.last == 0x0D {
                buffer.removeLast()
            }
            guard let line = String(data: buffer, encoding: .utf8) else {
                throw StatsPackError.unreadableUTF8Line(line: lineNumber)
            }
            try body(line, lineNumber)
        }
    }
}
