//! Monowiki integration for design document context.
//!
//! Provides CLI wrapper functions for searching, fetching notes,
//! and querying the document graph from a monowiki vault.

const std = @import("std");
const process = @import("process.zig");

/// Configuration for context exclusions
pub const ExclusionConfig = struct {
    /// Directory patterns to exclude (e.g., "vendor/", "node_modules/")
    excluded_dirs: []const []const u8 = &default_excluded_dirs,

    /// File extension patterns to exclude (e.g., ".min.js", ".proto")
    excluded_extensions: []const []const u8 = &default_excluded_extensions,

    /// Files to exclude by name (e.g., "package-lock.json")
    excluded_files: []const []const u8 = &default_excluded_files,

    /// Maximum file size in KB (files larger are excluded unless explicitly requested)
    max_file_size_kb: u32 = 100,

    /// Whether exclusions are user-customized (affects memory ownership)
    is_customized: bool = false,

    pub const default_excluded_dirs: [5][]const u8 = .{
        "vendor/",
        "node_modules/",
        "dist/",
        "build/",
        ".cache/",
    };

    pub const default_excluded_extensions: [4][]const u8 = .{
        ".min.js",
        ".min.css",
        ".pb.go",
        ".pb.zig",
    };

    pub const default_excluded_files: [6][]const u8 = .{
        "package-lock.json",
        "yarn.lock",
        "pnpm-lock.yaml",
        "Cargo.lock",
        "go.sum",
        "composer.lock",
    };
};

/// Configuration for monowiki integration
pub const MonowikiConfig = struct {
    /// Path to the monowiki vault
    vault: []const u8,

    /// Enable proactive search before implementation
    proactive_search: bool = true,

    /// Resolve [[wikilinks]] in issue descriptions
    resolve_wikilinks: bool = true,

    /// Expand to graph neighbors of referenced docs
    expand_neighbors: bool = false,

    /// Depth for neighbor expansion (1 = direct neighbors only)
    neighbor_depth: u8 = 1,

    /// Slug for API documentation (for bidirectional sync)
    api_docs_slug: ?[]const u8 = null,

    /// Enable API doc updates after implementation
    sync_api_docs: bool = false,

    /// Maximum documents to inject into prompt context
    max_context_docs: u8 = 5,

    /// Exclusion configuration for context retrieval
    exclusions: ExclusionConfig = .{},
};

/// A search result from monowiki
pub const SearchResult = struct {
    slug: []const u8,
    title: []const u8,
    excerpt: []const u8,
    score: f32,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.title);
        allocator.free(self.excerpt);
    }
};

/// A note fetched from monowiki
pub const Note = struct {
    slug: []const u8,
    title: []const u8,
    content: []const u8,

    pub fn deinit(self: *Note, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.title);
        allocator.free(self.content);
    }
};

/// A graph neighbor
pub const Neighbor = struct {
    slug: []const u8,
    title: []const u8,
    link_type: []const u8, // "outgoing" or "incoming"

    pub fn deinit(self: *Neighbor, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.title);
        allocator.free(self.link_type);
    }
};

/// Monowiki client for interacting with the CLI
pub const Monowiki = struct {
    allocator: std.mem.Allocator,
    config: MonowikiConfig,

    pub fn init(allocator: std.mem.Allocator, config: MonowikiConfig) Monowiki {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Check if monowiki CLI is available
    pub fn isAvailable(self: *Monowiki) bool {
        return process.commandExists(self.allocator, "monowiki");
    }

    /// Check if a path should be excluded from context retrieval.
    /// Returns true if the path matches any exclusion pattern.
    pub fn shouldExclude(self: *const Monowiki, path: []const u8) bool {
        return shouldExcludePath(path, &self.config.exclusions);
    }

    /// Search for documents matching a query
    pub fn search(self: *Monowiki, query: []const u8, limit: u8) ![]SearchResult {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "cd \"{s}\" && monowiki search \"{s}\" --json --limit {d}",
            .{ self.config.vault, query, limit },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success() or result.stdout.len == 0) {
            return &[_]SearchResult{};
        }

        return self.parseSearchResults(result.stdout);
    }

    /// Fetch a note by slug
    pub fn fetchNote(self: *Monowiki, slug: []const u8) !?Note {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "cd \"{s}\" && monowiki note \"{s}\" --format json",
            .{ self.config.vault, slug },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success() or result.stdout.len == 0) {
            return null;
        }

        return self.parseNote(result.stdout);
    }

    /// Get neighbors of a document in the graph
    pub fn getNeighbors(self: *Monowiki, slug: []const u8) ![]Neighbor {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "cd \"{s}\" && monowiki graph neighbors --slug \"{s}\" --json",
            .{ self.config.vault, slug },
        );
        defer self.allocator.free(cmd);

        var result = try process.shell(self.allocator, cmd);
        defer result.deinit();

        if (!result.success() or result.stdout.len == 0) {
            return &[_]Neighbor{};
        }

        return self.parseNeighbors(result.stdout);
    }

    /// Extract [[wikilinks]] from text
    pub fn extractWikilinks(self: *Monowiki, text: []const u8) ![][]const u8 {
        var links = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (links.items) |link| {
                self.allocator.free(link);
            }
            links.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < text.len) {
            // Look for [[
            if (i + 1 < text.len and text[i] == '[' and text[i + 1] == '[') {
                const start = i + 2;
                var end = start;

                // Find closing ]]
                while (end + 1 < text.len) {
                    if (text[end] == ']' and text[end + 1] == ']') {
                        const link = text[start..end];
                        // Only add if not already present
                        var found = false;
                        for (links.items) |existing| {
                            if (std.mem.eql(u8, existing, link)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            try links.append(self.allocator, try self.allocator.dupe(u8, link));
                        }
                        i = end + 2;
                        break;
                    }
                    end += 1;
                }
                if (end + 1 >= text.len) {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        return links.toOwnedSlice(self.allocator);
    }

    /// Extract keywords from issue title/description for search
    pub fn extractKeywords(self: *Monowiki, text: []const u8) ![]const u8 {
        // Simple keyword extraction: take first 100 chars, remove special chars
        const max_len = @min(text.len, 100);
        var keywords = try self.allocator.alloc(u8, max_len);
        var j: usize = 0;

        for (text[0..max_len]) |c| {
            if (std.ascii.isAlphanumeric(c) or c == ' ' or c == '-') {
                keywords[j] = c;
                j += 1;
            } else if (c == '\n' or c == '\r') {
                // Replace newlines with space
                if (j > 0 and keywords[j - 1] != ' ') {
                    keywords[j] = ' ';
                    j += 1;
                }
            }
        }

        // Trim trailing spaces
        while (j > 0 and keywords[j - 1] == ' ') {
            j -= 1;
        }

        if (j == 0) {
            self.allocator.free(keywords);
            return try self.allocator.dupe(u8, "");
        }

        // Shrink to actual size
        const result = try self.allocator.realloc(keywords, j);
        return result;
    }

    /// Build context string from search results and fetched notes
    pub fn buildContext(
        self: *Monowiki,
        search_results: []const SearchResult,
        wikilink_notes: []const Note,
    ) ![]const u8 {
        var context = std.ArrayListUnmanaged(u8){};
        errdefer context.deinit(self.allocator);

        // Add wikilink-resolved notes first (higher priority)
        for (wikilink_notes) |note| {
            try context.appendSlice(self.allocator, "---\n## ");
            try context.appendSlice(self.allocator, note.title);
            try context.appendSlice(self.allocator, " (");
            try context.appendSlice(self.allocator, note.slug);
            try context.appendSlice(self.allocator, ")\n");
            // Truncate content if too long
            const max_content = 2000;
            if (note.content.len > max_content) {
                try context.appendSlice(self.allocator, note.content[0..max_content]);
                try context.appendSlice(self.allocator, "\n[... truncated ...]\n");
            } else {
                try context.appendSlice(self.allocator, note.content);
                try context.appendSlice(self.allocator, "\n");
            }
        }

        // Add search results (excerpts only to save space)
        if (search_results.len > 0) {
            try context.appendSlice(self.allocator, "\n### Related Documents (from search)\n");
            for (search_results) |result| {
                // Skip if already included via wikilink
                var already_included = false;
                for (wikilink_notes) |note| {
                    if (std.mem.eql(u8, note.slug, result.slug)) {
                        already_included = true;
                        break;
                    }
                }
                if (already_included) continue;

                try context.appendSlice(self.allocator, "- **");
                try context.appendSlice(self.allocator, result.title);
                try context.appendSlice(self.allocator, "** (`");
                try context.appendSlice(self.allocator, result.slug);
                try context.appendSlice(self.allocator, "`): ");
                try context.appendSlice(self.allocator, result.excerpt);
                try context.appendSlice(self.allocator, "\n");
            }
        }

        if (context.items.len == 0) {
            return try self.allocator.dupe(u8, "");
        }

        return context.toOwnedSlice(self.allocator);
    }

    /// Free a slice of search results
    pub fn freeSearchResults(self: *Monowiki, results: []SearchResult) void {
        for (results) |*result| {
            result.deinit(self.allocator);
        }
        self.allocator.free(results);
    }

    /// Free a slice of notes
    pub fn freeNotes(self: *Monowiki, notes: []Note) void {
        for (notes) |*note| {
            note.deinit(self.allocator);
        }
        self.allocator.free(notes);
    }

    /// Free a slice of neighbors
    pub fn freeNeighbors(self: *Monowiki, neighbors: []Neighbor) void {
        for (neighbors) |*neighbor| {
            neighbor.deinit(self.allocator);
        }
        self.allocator.free(neighbors);
    }

    /// Free a slice of wikilinks
    pub fn freeWikilinks(self: *Monowiki, links: [][]const u8) void {
        for (links) |link| {
            self.allocator.free(link);
        }
        self.allocator.free(links);
    }

    // JSON parsing helpers

    fn parseSearchResults(self: *Monowiki, json: []const u8) ![]SearchResult {
        var results = std.ArrayListUnmanaged(SearchResult){};
        errdefer {
            for (results.items) |*r| {
                r.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        // Parse JSON array of search results
        // Expected format: [{"slug": "...", "title": "...", "excerpt": "...", "score": 0.5}, ...]
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch {
            return results.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) {
            return results.toOwnedSlice(self.allocator);
        }

        for (root.array.items) |item| {
            if (item != .object) continue;

            const obj = item.object;
            const slug = if (obj.get("slug")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            const title = if (obj.get("title")) |v| switch (v) {
                .string => |s| s,
                else => slug,
            } else slug;

            const excerpt = if (obj.get("excerpt")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else "";

            const score: f32 = if (obj.get("score")) |v| switch (v) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => 0.0,
            } else 0.0;

            try results.append(self.allocator, .{
                .slug = try self.allocator.dupe(u8, slug),
                .title = try self.allocator.dupe(u8, title),
                .excerpt = try self.allocator.dupe(u8, excerpt),
                .score = score,
            });
        }

        return results.toOwnedSlice(self.allocator);
    }

    fn parseNote(self: *Monowiki, json: []const u8) !?Note {
        // Expected format: {"slug": "...", "title": "...", "content": "..."}
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch {
            return null;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return null;
        }

        const obj = root.object;
        const slug = if (obj.get("slug")) |v| switch (v) {
            .string => |s| s,
            else => return null,
        } else return null;

        const title = if (obj.get("title")) |v| switch (v) {
            .string => |s| s,
            else => slug,
        } else slug;

        const content = if (obj.get("content")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        return .{
            .slug = try self.allocator.dupe(u8, slug),
            .title = try self.allocator.dupe(u8, title),
            .content = try self.allocator.dupe(u8, content),
        };
    }

    fn parseNeighbors(self: *Monowiki, json: []const u8) ![]Neighbor {
        var neighbors = std.ArrayListUnmanaged(Neighbor){};
        errdefer {
            for (neighbors.items) |*n| {
                n.deinit(self.allocator);
            }
            neighbors.deinit(self.allocator);
        }

        // Expected format: [{"slug": "...", "title": "...", "type": "outgoing"}, ...]
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch {
            return neighbors.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) {
            return neighbors.toOwnedSlice(self.allocator);
        }

        for (root.array.items) |item| {
            if (item != .object) continue;

            const obj = item.object;
            const slug = if (obj.get("slug")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            const title = if (obj.get("title")) |v| switch (v) {
                .string => |s| s,
                else => slug,
            } else slug;

            const link_type = if (obj.get("type")) |v| switch (v) {
                .string => |s| s,
                else => "unknown",
            } else "unknown";

            try neighbors.append(self.allocator, .{
                .slug = try self.allocator.dupe(u8, slug),
                .title = try self.allocator.dupe(u8, title),
                .link_type = try self.allocator.dupe(u8, link_type),
            });
        }

        return neighbors.toOwnedSlice(self.allocator);
    }
};

/// Check if a path should be excluded from context retrieval based on exclusion rules.
/// This is a standalone function that can be used outside of Monowiki context.
pub fn shouldExcludePath(path: []const u8, exclusions: *const ExclusionConfig) bool {
    // Check excluded directories
    for (exclusions.excluded_dirs) |dir| {
        if (pathContainsDir(path, dir)) {
            return true;
        }
    }

    // Check excluded extensions
    for (exclusions.excluded_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) {
            return true;
        }
    }

    // Check excluded files by name
    const basename = getBasename(path);
    for (exclusions.excluded_files) |file| {
        if (std.mem.eql(u8, basename, file)) {
            return true;
        }
    }

    return false;
}

/// Check if a path contains a directory component matching the pattern.
/// Pattern should end with '/' (e.g., "node_modules/").
fn pathContainsDir(path: []const u8, dir_pattern: []const u8) bool {
    // Handle patterns without trailing slash gracefully
    const pattern = if (dir_pattern.len > 0 and dir_pattern[dir_pattern.len - 1] == '/')
        dir_pattern[0 .. dir_pattern.len - 1]
    else
        dir_pattern;

    if (pattern.len == 0) return false;

    // Check if path starts with the pattern
    if (path.len >= pattern.len) {
        if (std.mem.startsWith(u8, path, pattern)) {
            // Either exact match or followed by '/'
            if (path.len == pattern.len or path[pattern.len] == '/') {
                return true;
            }
        }
    }

    // Check for pattern as a directory component within the path
    var i: usize = 0;
    while (i < path.len) {
        // Skip to next '/'
        while (i < path.len and path[i] != '/') {
            i += 1;
        }
        if (i >= path.len) break;
        i += 1; // Skip the '/'

        // Check if the remaining path starts with the pattern
        const remaining = path[i..];
        if (remaining.len >= pattern.len) {
            if (std.mem.startsWith(u8, remaining, pattern)) {
                // Either at end or followed by '/'
                if (remaining.len == pattern.len or remaining[pattern.len] == '/') {
                    return true;
                }
            }
        }
    }

    return false;
}

/// Extract the basename (filename) from a path.
fn getBasename(path: []const u8) []const u8 {
    var last_sep: usize = 0;
    var found_sep = false;
    for (path, 0..) |c, i| {
        if (c == '/') {
            last_sep = i;
            found_sep = true;
        }
    }
    if (found_sep) {
        return path[last_sep + 1 ..];
    }
    return path;
}

/// Check if a file size exceeds the configured maximum.
/// size_bytes is the file size in bytes, max_kb is the limit in kilobytes.
pub fn exceedsMaxSize(size_bytes: u64, max_kb: u32) bool {
    const max_bytes: u64 = @as(u64, max_kb) * 1024;
    return size_bytes > max_bytes;
}

// Tests

test "extract wikilinks" {
    const allocator = std.testing.allocator;
    var mw = Monowiki.init(allocator, .{ .vault = "/tmp" });

    const text = "Implement the [[streaming-protocol]] parser according to [[json-spec]].";
    const links = try mw.extractWikilinks(text);
    defer mw.freeWikilinks(links);

    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expectEqualStrings("streaming-protocol", links[0]);
    try std.testing.expectEqualStrings("json-spec", links[1]);
}

test "extract wikilinks no duplicates" {
    const allocator = std.testing.allocator;
    var mw = Monowiki.init(allocator, .{ .vault = "/tmp" });

    const text = "See [[foo]] and [[bar]] and [[foo]] again.";
    const links = try mw.extractWikilinks(text);
    defer mw.freeWikilinks(links);

    try std.testing.expectEqual(@as(usize, 2), links.len);
}

test "extract keywords" {
    const allocator = std.testing.allocator;
    var mw = Monowiki.init(allocator, .{ .vault = "/tmp" });

    const text = "Implement streaming JSON parser!";
    const keywords = try mw.extractKeywords(text);
    defer allocator.free(keywords);

    try std.testing.expectEqualStrings("Implement streaming JSON parser", keywords);
}

test "extract keywords from multiline" {
    const allocator = std.testing.allocator;
    var mw = Monowiki.init(allocator, .{ .vault = "/tmp" });

    const text = "Implement feature\nWith multiple lines";
    const keywords = try mw.extractKeywords(text);
    defer allocator.free(keywords);

    try std.testing.expectEqualStrings("Implement feature With multiple lines", keywords);
}

test "exclude paths with node_modules" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(shouldExcludePath("node_modules/lodash/index.js", &exclusions));
    try std.testing.expect(shouldExcludePath("src/node_modules/foo/bar.js", &exclusions));
    try std.testing.expect(shouldExcludePath("web/node_modules/react/index.js", &exclusions));
}

test "exclude paths with vendor" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(shouldExcludePath("vendor/package/file.go", &exclusions));
    try std.testing.expect(shouldExcludePath("src/vendor/lib/module.rs", &exclusions));
}

test "exclude paths with build directories" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(shouldExcludePath("dist/bundle.js", &exclusions));
    try std.testing.expect(shouldExcludePath("build/output/main.o", &exclusions));
    try std.testing.expect(shouldExcludePath(".cache/babel/file.json", &exclusions));
}

test "exclude minified files" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(shouldExcludePath("assets/app.min.js", &exclusions));
    try std.testing.expect(shouldExcludePath("styles/main.min.css", &exclusions));
}

test "exclude protobuf generated files" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(shouldExcludePath("proto/message.pb.go", &exclusions));
    try std.testing.expect(shouldExcludePath("src/gen/types.pb.zig", &exclusions));
}

test "exclude lockfiles" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(shouldExcludePath("package-lock.json", &exclusions));
    try std.testing.expect(shouldExcludePath("project/yarn.lock", &exclusions));
    try std.testing.expect(shouldExcludePath("nested/path/pnpm-lock.yaml", &exclusions));
    try std.testing.expect(shouldExcludePath("Cargo.lock", &exclusions));
    try std.testing.expect(shouldExcludePath("go.sum", &exclusions));
    try std.testing.expect(shouldExcludePath("vendor/composer.lock", &exclusions));
}

test "allow normal source files" {
    const exclusions = ExclusionConfig{};
    try std.testing.expect(!shouldExcludePath("src/main.zig", &exclusions));
    try std.testing.expect(!shouldExcludePath("lib/utils.js", &exclusions));
    try std.testing.expect(!shouldExcludePath("app/models/user.go", &exclusions));
    try std.testing.expect(!shouldExcludePath("package.json", &exclusions));
}

test "allow files with similar names to excluded dirs" {
    const exclusions = ExclusionConfig{};
    // "node_modules_backup" should NOT be excluded
    try std.testing.expect(!shouldExcludePath("node_modules_backup/file.js", &exclusions));
    // "vendorlib" should NOT be excluded
    try std.testing.expect(!shouldExcludePath("vendorlib/code.rs", &exclusions));
    // "buildscript.sh" should NOT be excluded
    try std.testing.expect(!shouldExcludePath("buildscript.sh", &exclusions));
}

test "exceeds max size" {
    // 100 KB limit (default)
    try std.testing.expect(!exceedsMaxSize(50 * 1024, 100)); // 50 KB - allowed
    try std.testing.expect(!exceedsMaxSize(100 * 1024, 100)); // exactly 100 KB - allowed
    try std.testing.expect(exceedsMaxSize(101 * 1024, 100)); // 101 KB - excluded
    try std.testing.expect(exceedsMaxSize(1024 * 1024, 100)); // 1 MB - excluded
}

test "getBasename" {
    try std.testing.expectEqualStrings("file.txt", getBasename("path/to/file.txt"));
    try std.testing.expectEqualStrings("file.txt", getBasename("file.txt"));
    try std.testing.expectEqualStrings("", getBasename("path/to/dir/"));
}

test "pathContainsDir" {
    try std.testing.expect(pathContainsDir("node_modules/foo/bar.js", "node_modules/"));
    try std.testing.expect(pathContainsDir("src/node_modules/foo.js", "node_modules/"));
    try std.testing.expect(!pathContainsDir("node_modules_backup/foo.js", "node_modules/"));
    try std.testing.expect(!pathContainsDir("src/mynode_modules/foo.js", "node_modules/"));
}
