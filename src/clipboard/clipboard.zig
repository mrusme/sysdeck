const std = @import("std");
const zqlite = @import("zqlite");
const store_mod = @import("core").store;
const tables = @import("core").tables;
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.clipboard);

pub const table = tables.clipboard;
pub const digest_len = std.crypto.hash.sha2.Sha256.digest_length;
pub const preview_bytes = 512;

pub const Digest = [digest_len]u8;

const schema =
    \\CREATE TABLE IF NOT EXISTS clipboard(
    \\  id         INTEGER PRIMARY KEY,
    \\  digest     BLOB    NOT NULL UNIQUE,
    \\  mime       TEXT    NOT NULL,
    \\  icon       TEXT    NOT NULL,
    \\  preview    TEXT    NOT NULL,
    \\  bytes      INTEGER NOT NULL,
    \\  content    BLOB    NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  copied     INTEGER NOT NULL DEFAULT 1);
    \\CREATE INDEX IF NOT EXISTS clipboard_recent ON clipboard(updated_at DESC);
;

const insert_sql =
    \\INSERT INTO clipboard(digest, mime, icon, preview, bytes, content, created_at, updated_at)
    \\VALUES(?1,?2,?3,?4,?5,?6,?7,?7)
    \\ON CONFLICT(digest) DO UPDATE SET copied = copied + 1, updated_at = excluded.updated_at
;

const recent_sql =
    \\SELECT id, digest, mime, icon, preview, bytes, created_at, updated_at, copied
    \\  FROM clipboard ORDER BY updated_at DESC LIMIT ?1
;

const content_sql = "SELECT mime, content FROM clipboard WHERE id = ?1";

const trim_count_sql =
    \\DELETE FROM clipboard WHERE id NOT IN
    \\  (SELECT id FROM clipboard ORDER BY updated_at DESC LIMIT ?1)
;

const trim_age_sql = "DELETE FROM clipboard WHERE updated_at < ?1";

const wipe_sql = "DELETE FROM clipboard";

const newest_sql =
    \\DELETE FROM clipboard WHERE id =
    \\  (SELECT id FROM clipboard ORDER BY updated_at DESC LIMIT 1)
;

pub const Limits = struct {
    max_items: i64 = 750,
    max_age_days: i64 = 30,
    max_size_bytes: usize = 5 << 20,
    min_length: usize = 0,
};

pub const Entry = struct {
    id: i64,
    digest: Digest,
    mime: []const u8,
    icon: []const u8,
    preview: []const u8,
    bytes: i64,
    created_at: i64,
    updated_at: i64,
    copied: u32,
};

pub const Content = struct {
    mime: []const u8,
    bytes: []const u8,
};

pub const Record = struct {
    digest: Digest,
    mime: []const u8,
    icon: []const u8,
    preview: []const u8,
    content: []const u8,
    at: i64,
};

pub const Store = struct {
    gpa: Allocator,
    conn: zqlite.Conn,

    pub fn open(gpa: Allocator, io: std.Io, path: []const u8) !Store {
        try store_mod.prepare(io, path);

        const owned = try gpa.dupeZ(u8, path);
        defer gpa.free(owned);

        return openAt(gpa, owned);
    }

    pub fn openAt(gpa: Allocator, path: [:0]const u8) !Store {
        const conn = try store_mod.connect(path, .{ .auto_vacuum = true });
        errdefer conn.close();

        try conn.execNoArgs(schema);

        return .{ .gpa = gpa, .conn = conn };
    }

    pub fn close(self: *Store) void {
        self.conn.close();
    }

    pub fn put(self: *Store, record: Record) !void {
        try self.conn.exec(insert_sql, .{
            zqlite.blob(&record.digest),
            record.mime,
            record.icon,
            record.preview,
            @as(i64, @intCast(record.content.len)),
            zqlite.blob(record.content),
            record.at,
        });
    }

    pub fn recent(self: *Store, arena: Allocator, limit: i64) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;

        var rows = try self.conn.rows(recent_sql, .{limit});
        defer rows.deinit();

        while (rows.next()) |row| {
            try entries.append(arena, .{
                .id = row.int(0),
                .digest = digestFrom(row.blob(1)),
                .mime = try arena.dupe(u8, row.text(2)),
                .icon = try arena.dupe(u8, row.text(3)),
                .preview = try arena.dupe(u8, row.text(4)),
                .bytes = row.int(5),
                .created_at = row.int(6),
                .updated_at = row.int(7),
                .copied = count(row.int(8)),
            });
        }
        if (rows.err) |err| return err;

        return entries.toOwnedSlice(arena);
    }

    pub fn contentOf(self: *Store, arena: Allocator, id: i64) !?Content {
        const found = try self.conn.row(content_sql, .{id});
        const row = found orelse return null;
        defer row.deinit();

        return .{
            .mime = try arena.dupe(u8, row.text(0)),
            .bytes = try arena.dupe(u8, row.blob(1)),
        };
    }

    pub fn trim(self: *Store, limits: Limits, at: i64) void {
        self.prune(limits, at) catch |err| self.report("trim the history", err);
    }

    pub fn wipe(self: *Store) usize {
        return self.erase() catch |err| block: {
            self.report("clear the history", err);
            break :block 0;
        };
    }

    fn erase(self: *Store) !usize {
        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.execNoArgs(wipe_sql);
        const removed = self.conn.changes();

        try self.conn.commit();

        if (removed > 0) self.reclaim();
        return removed;
    }

    fn reclaim(self: *Store) void {
        self.conn.execNoArgs("PRAGMA incremental_vacuum") catch |err| {
            log.debug("cannot return the freed pages: {t}", .{err});
        };
        self.conn.execNoArgs("PRAGMA wal_checkpoint(TRUNCATE)") catch |err| {
            log.debug("cannot truncate the write ahead log: {t}", .{err});
        };
    }

    pub fn deleteNewest(self: *Store) void {
        self.conn.execNoArgs(newest_sql) catch |err| {
            self.report("delete the newest entry", err);
        };
    }

    fn prune(self: *Store, limits: Limits, at: i64) !void {
        var removed: usize = 0;

        if (limits.max_items > 0) {
            try self.conn.exec(trim_count_sql, .{limits.max_items});
            removed += self.conn.changes();
        }

        if (limits.max_age_days > 0) {
            try self.conn.exec(trim_age_sql, .{oldest(limits.max_age_days, at)});
            removed += self.conn.changes();
        }

        if (removed > 0) try self.conn.execNoArgs("PRAGMA incremental_vacuum");
    }

    fn report(self: *Store, action: []const u8, err: anyerror) void {
        log.warn("cannot {s}: {t}: {s}", .{ action, err, self.conn.lastError() });
    }
};

fn digestFrom(stored: []const u8) Digest {
    var out: Digest = undefined;
    const wanted = @min(stored.len, out.len);
    @memcpy(out[0..wanted], stored[0..wanted]);
    if (wanted < out.len) @memset(out[wanted..], 0);
    return out;
}

pub fn digestOf(bytes: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

pub fn oldest(max_age_days: i64, at: i64) i64 {
    return at -| max_age_days *| std.time.ms_per_day;
}

pub fn defaultPath(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    return xdg.path(gpa, environ, .data, &.{ "sysdeck", "clipboard.db" });
}

fn count(value: i64) u32 {
    return std.math.cast(u32, value) orelse 0;
}

const testing = std.testing;

fn openMemory() !Store {
    return Store.openAt(testing.allocator, ":memory:");
}

fn settingOf(conn: zqlite.Conn, sql: [:0]const u8) !zqlite.Row {
    const found = try conn.row(sql, .{});
    return found orelse error.NoSetting;
}

test "a history file gets both the write ahead log and incremental vacuum" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &buffer,
        ".zig-cache/tmp/{s}/clipboard.db",
        .{tmp.sub_path},
    );

    var self = try Store.openAt(testing.allocator, path);
    defer self.close();

    const journal = try settingOf(self.conn, "PRAGMA journal_mode");
    defer journal.deinit();
    try testing.expectEqualStrings("wal", journal.text(0));

    const vacuum = try settingOf(self.conn, "PRAGMA auto_vacuum");
    defer vacuum.deinit();
    try testing.expectEqual(@as(i64, 2), vacuum.int(0));
}

fn text(body: []const u8, at: i64) Record {
    return .{
        .digest = digestOf(body),
        .mime = "text/plain",
        .icon = "text-x-generic",
        .preview = body,
        .content = body,
        .at = at,
    };
}

fn read(self: *Store, arena: Allocator, limit: i64) ![]Entry {
    return self.recent(arena, limit);
}

test "an entry goes in and comes back" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("hello", 1000));

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("hello", found[0].preview);
    try testing.expectEqualStrings("text/plain", found[0].mime);
    try testing.expectEqual(@as(i64, 5), found[0].bytes);
    try testing.expectEqual(@as(i64, 1000), found[0].created_at);
    try testing.expectEqual(@as(i64, 1000), found[0].updated_at);
    try testing.expectEqual(@as(u32, 1), found[0].copied);
}

test "the same content bumps the counter rather than adding a row" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("hello", 1000));
    try self.put(text("hello", 2000));
    try self.put(text("hello", 3000));

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 3), found[0].copied);
    try testing.expectEqual(@as(i64, 1000), found[0].created_at);
    try testing.expectEqual(@as(i64, 3000), found[0].updated_at);
}

test "a repeat keeps the form the bytes first arrived in" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(.{
        .digest = digestOf("<svg/>"),
        .mime = "image/svg+xml",
        .icon = "image-svg+xml",
        .preview = "<svg/>",
        .content = "<svg/>",
        .at = 1000,
    });
    try self.put(text("<svg/>", 2000));

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("image/svg+xml", found[0].mime);
    try testing.expectEqual(@as(u32, 2), found[0].copied);
}

test "entries come back newest first" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("first", 1000));
    try self.put(text("second", 2000));
    try self.put(text("third", 1500));

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("second", found[0].preview);
    try testing.expectEqualStrings("third", found[1].preview);
    try testing.expectEqualStrings("first", found[2].preview);
}

test "a repeat moves an old entry back to the top" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("old", 1000));
    try self.put(text("new", 2000));
    try self.put(text("old", 3000));

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("old", found[0].preview);
}

test "a negative limit brings everything back" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("a", 1000));
    try self.put(text("b", 2000));
    try self.put(text("c", 3000));

    try testing.expectEqual(@as(usize, 3), (try read(&self, arena.allocator(), -1)).len);
    try testing.expectEqual(@as(usize, 0), (try read(&self, arena.allocator(), 0)).len);
}

test "the limit caps how many come back" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("a", 1000));
    try self.put(text("b", 2000));
    try self.put(text("c", 3000));

    const found = try read(&self, arena.allocator(), 2);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("c", found[0].preview);
}

test "the content comes back byte for byte" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const raw = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x00, 0xff };
    try self.put(.{
        .digest = digestOf(&raw),
        .mime = "image/png",
        .icon = "image-png",
        .preview = "",
        .content = &raw,
        .at = 1000,
    });

    const found = try read(&self, arena.allocator(), 100);
    const held = (try self.contentOf(arena.allocator(), found[0].id)).?;

    try testing.expectEqualStrings("image/png", held.mime);
    try testing.expectEqualSlices(u8, &raw, held.bytes);
}

test "an id that is gone has no content" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(@as(?Content, null), try self.contentOf(arena.allocator(), 42));
}

test "trimming keeps the newest entries" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (0..5) |at| {
        var buffer: [8]u8 = undefined;
        const body = try std.fmt.bufPrint(&buffer, "item{d}", .{at});
        try self.put(text(body, @intCast(1000 + at)));
    }

    self.trim(.{ .max_items = 2, .max_age_days = 0 }, 1004);

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("item4", found[0].preview);
    try testing.expectEqualStrings("item3", found[1].preview);
}

test "trimming drops what is older than the age" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const day = std.time.ms_per_day;
    try self.put(text("ancient", 0));
    try self.put(text("recent", 9 * day));

    self.trim(.{ .max_items = 0, .max_age_days = 7 }, 10 * day);

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("recent", found[0].preview);
}

test "a limit of zero turns that trim off" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("a", 0));
    try self.put(text("b", 1000));

    self.trim(.{ .max_items = 0, .max_age_days = 0 }, 1_000_000_000);

    try testing.expectEqual(@as(usize, 2), (try read(&self, arena.allocator(), 100)).len);
}

test "clearing takes every entry and says how many there were" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("first", 1000));
    try self.put(text("second", 2000));
    try self.put(text("third", 3000));

    try testing.expectEqual(@as(usize, 3), self.wipe());
    try testing.expectEqual(@as(usize, 0), (try read(&self, arena.allocator(), 100)).len);
}

test "clearing an empty history removes nothing and is not an error" {
    var self = try openMemory();
    defer self.close();

    try testing.expectEqual(@as(usize, 0), self.wipe());
    try testing.expectEqual(@as(usize, 0), self.wipe());
}

test "the table is still usable after a clear" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("before", 1000));
    _ = self.wipe();
    try self.put(text("after", 2000));

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("after", found[0].preview);
    try testing.expectEqual(@as(u32, 1), found[0].copied);
}

test "the newest entry can be deleted on its own" {
    var self = try openMemory();
    defer self.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try self.put(text("kept", 1000));
    try self.put(text("password", 2000));

    self.deleteNewest();

    const found = try read(&self, arena.allocator(), 100);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("kept", found[0].preview);
}

test "deleting the newest of nothing is not an error" {
    var self = try openMemory();
    defer self.close();

    self.deleteNewest();
}

test "the age cutoff cannot wrap" {
    const day = std.time.ms_per_day;

    try testing.expectEqual(@as(i64, 3 * day), oldest(7, 10 * day));
    try testing.expect(oldest(std.math.maxInt(i64), 0) < 0);
    try testing.expect(oldest(std.math.maxInt(i64), std.math.maxInt(i64)) < std.math.maxInt(i64));
}

test "the digest is stable and separates content" {
    try testing.expectEqual(digestOf("hello"), digestOf("hello"));
    try testing.expect(!std.mem.eql(u8, &digestOf("hello"), &digestOf("hellO")));
    try testing.expectEqual(@as(usize, 32), digest_len);
}
