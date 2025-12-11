//! BM25 search index for code retrieval.
//!
//! Lightweight lexical search that lets agents find relevant code
//! without stuffing full files into prompts.

const std = @import("std");

/// BM25 tuning parameters (Okapi BM25 defaults)
const K1: f64 = 1.2; // Term frequency saturation
const B: f64 = 0.75; // Length normalization factor

/// A document in the index
pub const Document = struct {
    id: []const u8, // e.g., "src/loop.zig:100-150"
    path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
    term_count: u32, // Total terms in document
};

/// Term frequency entry
const TermEntry = struct {
    doc_idx: u32,
    frequency: u32,
};

/// BM25 search index
pub const Index = struct {
    allocator: std.mem.Allocator,

    /// All indexed documents
    documents: std.ArrayListUnmanaged(Document),

    /// Inverted index: term -> list of (doc_idx, frequency)
    inverted: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TermEntry)),

    /// Total documents
    doc_count: u32,

    /// Average document length (in terms)
    avg_doc_len: f64,

    /// IDF cache: term -> idf score
    idf_cache: std.StringHashMapUnmanaged(f64),

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .allocator = allocator,
            .documents = .{},
            .inverted = .{},
            .doc_count = 0,
            .avg_doc_len = 0,
            .idf_cache = .{},
        };
    }

    pub fn deinit(self: *Index) void {
        // Free documents
        for (self.documents.items) |doc| {
            self.allocator.free(doc.id);
            self.allocator.free(doc.path);
            self.allocator.free(doc.content);
        }
        self.documents.deinit(self.allocator);

        // Free inverted index
        var inv_it = self.inverted.iterator();
        while (inv_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.inverted.deinit(self.allocator);

        // Free IDF cache
        var idf_it = self.idf_cache.iterator();
        while (idf_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.idf_cache.deinit(self.allocator);
    }

    /// Index a code file, splitting into chunks
    pub fn indexFile(self: *Index, path: []const u8, content: []const u8, chunk_lines: u32) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_num: u32 = 1;
        var chunk_start: u32 = 1;
        var chunk_content = std.ArrayListUnmanaged(u8){};
        defer chunk_content.deinit(self.allocator);

        while (lines.next()) |line| {
            try chunk_content.appendSlice(self.allocator, line);
            try chunk_content.append(self.allocator, '\n');

            if (line_num - chunk_start + 1 >= chunk_lines) {
                // Index this chunk
                try self.addDocument(path, chunk_start, line_num, chunk_content.items);
                chunk_start = line_num + 1;
                chunk_content.clearRetainingCapacity();
            }
            line_num += 1;
        }

        // Index remaining content
        if (chunk_content.items.len > 0) {
            try self.addDocument(path, chunk_start, line_num - 1, chunk_content.items);
        }
    }

    /// Add a single document to the index
    pub fn addDocument(self: *Index, path: []const u8, start: u32, end: u32, content: []const u8) !void {
        const doc_idx: u32 = @intCast(self.documents.items.len);

        // Create document ID
        const id = try std.fmt.allocPrint(self.allocator, "{s}:{d}-{d}", .{ path, start, end });

        // Count terms and build term frequency map
        var term_freqs = std.StringHashMapUnmanaged(u32){};
        defer term_freqs.deinit(self.allocator);

        var total_terms: u32 = 0;
        var tokens = tokenize(content);
        while (tokens.next()) |token| {
            if (token.len < 2) continue; // Skip single chars
            total_terms += 1;

            const gop = try term_freqs.getOrPut(self.allocator, token);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, token);
                gop.value_ptr.* = 1;
            }
        }

        // Add to documents list
        try self.documents.append(self.allocator, .{
            .id = id,
            .path = try self.allocator.dupe(u8, path),
            .start_line = start,
            .end_line = end,
            .content = try self.allocator.dupe(u8, content),
            .term_count = total_terms,
        });

        // Update inverted index
        var tf_it = term_freqs.iterator();
        while (tf_it.next()) |entry| {
            const term = entry.key_ptr.*;
            const freq = entry.value_ptr.*;

            const inv_gop = try self.inverted.getOrPut(self.allocator, term);
            if (!inv_gop.found_existing) {
                inv_gop.key_ptr.* = term; // Already duped above
                inv_gop.value_ptr.* = .{};
            } else {
                self.allocator.free(term); // Don't need duplicate
            }

            try inv_gop.value_ptr.append(self.allocator, .{
                .doc_idx = doc_idx,
                .frequency = freq,
            });
        }

        // Update stats
        self.doc_count += 1;
        self.avg_doc_len = @as(f64, @floatFromInt(self.totalTerms())) / @as(f64, @floatFromInt(self.doc_count));

        // Invalidate IDF cache (could be smarter about this)
        var idf_it = self.idf_cache.iterator();
        while (idf_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.idf_cache.clearRetainingCapacity();
    }

    fn totalTerms(self: *Index) u64 {
        var total: u64 = 0;
        for (self.documents.items) |doc| {
            total += doc.term_count;
        }
        return total;
    }

    /// Search for documents matching query
    pub fn search(self: *Index, query: []const u8, max_results: u32) ![]SearchResult {
        var scores = std.AutoHashMapUnmanaged(u32, f64){};
        defer scores.deinit(self.allocator);

        // Score each query term
        var query_tokens = tokenize(query);
        while (query_tokens.next()) |term| {
            if (term.len < 2) continue;

            const idf = try self.getIdf(term);
            const postings = self.inverted.get(term) orelse continue;

            for (postings.items) |entry| {
                const doc = self.documents.items[entry.doc_idx];
                const tf = @as(f64, @floatFromInt(entry.frequency));
                const doc_len = @as(f64, @floatFromInt(doc.term_count));

                // BM25 scoring formula
                const numerator = tf * (K1 + 1);
                const denominator = tf + K1 * (1 - B + B * (doc_len / self.avg_doc_len));
                const term_score = idf * (numerator / denominator);

                const gop = try scores.getOrPut(self.allocator, entry.doc_idx);
                if (gop.found_existing) {
                    gop.value_ptr.* += term_score;
                } else {
                    gop.value_ptr.* = term_score;
                }
            }
        }

        // Sort by score
        var results = std.ArrayListUnmanaged(SearchResult){};
        defer results.deinit(self.allocator);

        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            const doc = self.documents.items[entry.key_ptr.*];
            try results.append(self.allocator, .{
                .id = doc.id,
                .path = doc.path,
                .start_line = doc.start_line,
                .end_line = doc.end_line,
                .score = entry.value_ptr.*,
            });
        }

        // Sort descending by score
        std.mem.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // Truncate to max results and return owned slice
        const count = @min(results.items.len, max_results);
        return try self.allocator.dupe(SearchResult, results.items[0..count]);
    }

    /// Calculate IDF for a term (with caching)
    fn getIdf(self: *Index, term: []const u8) !f64 {
        if (self.idf_cache.get(term)) |cached| {
            return cached;
        }

        const df: f64 = if (self.inverted.get(term)) |postings|
            @floatFromInt(postings.items.len)
        else
            0;

        // IDF formula: log((N - df + 0.5) / (df + 0.5) + 1)
        const n: f64 = @floatFromInt(self.doc_count);
        const idf = @log((n - df + 0.5) / (df + 0.5) + 1);

        const owned_term = try self.allocator.dupe(u8, term);
        try self.idf_cache.put(self.allocator, owned_term, idf);

        return idf;
    }

    /// Build index from a directory
    pub fn indexDirectory(self: *Index, dir_path: []const u8, extensions: []const []const u8) !u32 {
        var indexed: u32 = 0;
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            // Check extension
            const ext = std.fs.path.extension(entry.basename);
            var matches = false;
            for (extensions) |wanted| {
                if (std.mem.eql(u8, ext, wanted)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;

            // Read and index file
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.path });
            defer self.allocator.free(full_path);

            const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            try self.indexFile(entry.path, content, 50); // 50-line chunks
            indexed += 1;
        }

        return indexed;
    }
};

/// Search result
pub const SearchResult = struct {
    id: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    score: f64,
};

/// Simple tokenizer for code
fn tokenize(text: []const u8) Tokenizer {
    return .{ .text = text, .pos = 0 };
}

const Tokenizer = struct {
    text: []const u8,
    pos: usize,

    pub fn next(self: *Tokenizer) ?[]const u8 {
        // Skip non-alphanumeric
        while (self.pos < self.text.len and !isTokenChar(self.text[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.text.len) return null;

        const start = self.pos;
        while (self.pos < self.text.len and isTokenChar(self.text[self.pos])) {
            self.pos += 1;
        }

        return self.text[start..self.pos];
    }

    fn isTokenChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }
};

// === Tests ===

test "basic indexing and search" {
    const allocator = std.testing.allocator;
    var index = Index.init(allocator);
    defer index.deinit();

    try index.addDocument("test.zig", 1, 10,
        \\fn parseJson(data: []const u8) !Value {
        \\    // Parse JSON data into a Value
        \\    var parser = Parser.init(data);
        \\    return parser.parse();
        \\}
    );

    try index.addDocument("other.zig", 1, 5,
        \\fn processData(input: []const u8) void {
        \\    // Process the input data
        \\}
    );

    const results = try index.search("parseJson", 10);
    defer allocator.free(results);

    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("test.zig:1-10", results[0].id);
}

test "tokenizer" {
    var tok = tokenize("fn parseJson(data: []const u8)");

    try std.testing.expectEqualStrings("fn", tok.next().?);
    try std.testing.expectEqualStrings("parseJson", tok.next().?);
    try std.testing.expectEqualStrings("data", tok.next().?);
    try std.testing.expectEqualStrings("const", tok.next().?);
    try std.testing.expectEqualStrings("u8", tok.next().?);
    try std.testing.expect(tok.next() == null);
}
