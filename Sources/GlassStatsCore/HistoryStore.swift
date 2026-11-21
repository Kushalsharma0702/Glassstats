import DarwinMetrics
import Foundation
import os

final class HistoryStore {
    private var db: OpaquePointer?
    private let log = Logger(subsystem: "org.glassstats.app", category: "history")

    init?() {
        let root = URL.applicationSupportDirectory.appending(path: "GlassStats", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("Could not create the history directory")
            return nil
        }
        guard sqlite3_open_v2(root.appending(path: "History.sqlite").path, &db,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              execute("PRAGMA secure_delete = ON"),
              execute("CREATE TABLE IF NOT EXISTS samples (time REAL PRIMARY KEY, cpu REAL, memory REAL, down REAL, up REAL)") else {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    func load(cutoff: Date) -> MetricHistory {
        var history = MetricHistory()
        var statement: OpaquePointer?
        let sql = "SELECT time, cpu, memory, down, up FROM samples WHERE time >= ? ORDER BY time"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return history }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        let paths: [WritableKeyPath<MetricHistory, HistoryBuffer>] = [\.cpu, \.memory, \.down, \.up]
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            for (index, path) in paths.enumerated() {
                let column = Int32(index + 1)
                if sqlite3_column_type(statement, column) != SQLITE_NULL {
                    history[keyPath: path].add(sqlite3_column_double(statement, column), at: date, cutoff: cutoff)
                }
            }
        }
        prune(before: cutoff)
        return history
    }

    func write(date: Date, values: [Double?], cutoff: Date) {
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?, ?)"
        guard values.count == 4, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        for (index, reading) in values.enumerated() {
            if let reading { sqlite3_bind_double(statement, Int32(index + 2), reading) }
            else { sqlite3_bind_null(statement, Int32(index + 2)) }
        }
        if sqlite3_step(statement) == SQLITE_DONE { prune(before: cutoff) }
    }

    private func prune(before cutoff: Date) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE time < ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func clear() {
        _ = execute("DELETE FROM samples")
    }

    private func execute(_ sql: String) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            log.error("Could not update local telemetry history")
            return false
        }
        return true
    }
}
