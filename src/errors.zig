const std = @import("std");
const Token = @import("lex.zig").Token;
const SourceMappings = @import("source_mapping.zig").SourceMappings;
const utils = @import("utils.zig");
const rc = @import("rc.zig");

pub const Diagnostics = struct {
    errors: std.ArrayListUnmanaged(ErrorDetails) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.errors.deinit(self.allocator);
    }

    pub fn append(self: *Diagnostics, error_details: ErrorDetails) !void {
        try self.errors.append(self.allocator, error_details);
    }

    pub fn renderToStdErr(self: *Diagnostics, cwd: std.fs.Dir, source: []const u8, source_mappings: ?SourceMappings) void {
        // Set the codepage to UTF-8 unconditionally to ensure that everything renders okay
        // TODO: Reset codepage afterwards?
        if (@import("builtin").os.tag == .windows) {
            _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
        }

        // TODO: take this as a param probably
        const colors = utils.Colors.detect();
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();
        const stderr = std.io.getStdErr().writer();
        for (self.errors.items) |err_details| {
            renderErrorMessage(stderr, colors, cwd, err_details, source, source_mappings) catch return;
        }
    }
};

pub const ErrorDetails = struct {
    err: Error,
    token: Token,
    // TODO: I don't really like this; notes at least should probably be handled differently
    type: enum { err, warning, note } = .err,
    print_source_line: bool = true,
    extra: union {
        none: void,
        expected: Token.Id,
        number: u32,
        expected_types: ExpectedTypes,
        resource: rc.Resource,
    } = .{ .none = {} },

    pub const ExpectedTypes = packed struct(u32) {
        number: bool = false,
        number_expression: bool = false,
        string_literal: bool = false,
        _: u29 = undefined,

        pub const strings = std.ComptimeStringMap([]const u8, .{
            .{ "number", "number" },
            .{ "number_expression", "number expression" },
            .{ "string_literal", "quoted string literal" },
        });

        pub fn writeCommaSeparated(self: ExpectedTypes, writer: anytype) !void {
            const struct_info = @typeInfo(ExpectedTypes).Struct;
            const num_real_fields = struct_info.fields.len - 1;
            const num_padding_bits = @sizeOf(ExpectedTypes) - num_real_fields;
            const mask = std.math.maxInt(struct_info.backing_integer.?) >> num_padding_bits;
            const relevant_bits_only = @bitCast(struct_info.backing_integer.?, self) & mask;
            const num_set_bits = @popCount(relevant_bits_only);

            var i: usize = 0;
            inline for (struct_info.fields) |field_info| {
                if (field_info.field_type != bool) continue;
                if (i == num_set_bits) return;
                if (@field(self, field_info.name)) {
                    try writer.writeAll(strings.get(field_info.name).?);
                    i += 1;
                    if (num_set_bits > 2 and i != num_set_bits) {
                        try writer.writeAll(", ");
                    } else if (i != num_set_bits) {
                        try writer.writeByte(' ');
                    }
                    if (num_set_bits > 1 and i == num_set_bits - 1) {
                        try writer.writeAll("or ");
                    }
                }
            }
        }
    };

    pub const Error = enum {
        // Lexer
        unfinished_string_literal,
        string_literal_too_long,
        illegal_byte,
        illegal_byte_outside_string_literals,
        found_c_style_escaped_quote,

        // Parser
        unfinished_raw_data_block,
        unfinished_string_table_block,
        /// `expected` is populated.
        expected_token,
        /// `expected_types` is populated
        expected_something_else,
        /// `resource` is populated
        resource_type_cant_use_raw_data,
        /// `resource` is populated
        id_must_be_ordinal,

        // Compiler
        string_resource_as_numeric_type,
        /// `number` is populated
        string_already_defined,
    };

    pub fn render(self: ErrorDetails, writer: anytype, source: []const u8) !void {
        switch (self.err) {
            .unfinished_string_literal => {
                return writer.print("unfinished string literal at '{s}', expected closing '\"'", .{self.token.nameForErrorDisplay(source)});
            },
            .string_literal_too_long => {
                return writer.writeAll("string literal too long (max is 4097 characters)");
            },
            .illegal_byte => {
                const byte = self.token.slice(source)[0];
                return writer.print("character '\\x{X:0>2}' is not allowed", .{byte});
            },
            .illegal_byte_outside_string_literals => {
                const byte = self.token.slice(source)[0];
                return writer.print("character '\\x{X:0>2}' is not allowed outside of string literals", .{byte});
            },
            .found_c_style_escaped_quote => {
                return writer.writeAll("escaping quotes with \\\" is not allowed (use \"\" instead)");
            },
            .unfinished_raw_data_block => {
                return writer.print("unfinished raw data block at '{s}', expected closing '}}' or 'END'", .{self.token.nameForErrorDisplay(source)});
            },
            .unfinished_string_table_block => {
                return writer.print("unfinished STRINGTABLE block at '{s}', expected closing '}}' or 'END'", .{self.token.nameForErrorDisplay(source)});
            },
            .expected_token => {
                return writer.print("expected '{s}', got '{s}'", .{ self.extra.expected.nameForErrorDisplay(), self.token.nameForErrorDisplay(source) });
            },
            .expected_something_else => {
                try writer.writeAll("expected ");
                try self.extra.expected_types.writeCommaSeparated(writer);
                return writer.print("; got '{s}'", .{self.token.nameForErrorDisplay(source)});
            },
            .resource_type_cant_use_raw_data => switch (self.type) {
                .err, .warning => try writer.print("expected '<filename>', found '{s}' (resource type '{s}' can't use raw data)", .{ self.token.nameForErrorDisplay(source), @tagName(self.extra.resource) }),
                .note => try writer.print("if '{s}' is intended to be a filename, it must be specified as a quoted string literal", .{self.token.nameForErrorDisplay(source)}),
            },
            .id_must_be_ordinal => {
                try writer.print("id of resource type '{s}' must be an ordinal (u16), got '{s}'", .{ @tagName(self.extra.resource), self.token.nameForErrorDisplay(source) });
            },
            .string_resource_as_numeric_type => {
                // TODO: Add note about why this is the case (i.e. it always (?) leads to an invalid .res)
                return writer.writeAll("the number 6 (RT_STRING) can not be used as a resource type");
            },
            .string_already_defined => switch (self.type) {
                .err, .warning => return writer.print("string with id {d} (0x{X}) already defined", .{ self.extra.number, self.extra.number }),
                .note => return writer.print("previous definition of string with id {d} (0x{X}) here", .{ self.extra.number, self.extra.number }),
            },
        }
    }
};

pub fn renderErrorMessage(writer: anytype, colors: utils.Colors, cwd: std.fs.Dir, err_details: ErrorDetails, source: []const u8, source_mappings: ?SourceMappings) !void {
    const source_line_start = err_details.token.getLineStart(source);
    const column = err_details.token.calculateColumn(source, 1, source_line_start);

    // var counting_writer_container = std.io.countingWriter(writer);
    // const counting_writer = counting_writer_container.writer();

    colors.set(writer, .bold);
    colors.set(writer, .dim);
    try writer.writeAll("<after preprocessor>");
    colors.set(writer, .reset);
    colors.set(writer, .bold);
    try writer.print(":{d}:{d}: ", .{ err_details.token.line_number, column });
    switch (err_details.type) {
        .err => {
            colors.set(writer, .red);
            try writer.writeAll("error: ");
        },
        .warning => {
            colors.set(writer, .yellow);
            try writer.writeAll("warning: ");
        },
        .note => {
            colors.set(writer, .cyan);
            try writer.writeAll("note: ");
        },
    }
    colors.set(writer, .reset);
    colors.set(writer, .bold);
    try err_details.render(writer, source);
    try writer.writeAll("\n");
    colors.set(writer, .reset);

    if (!err_details.print_source_line) return;

    const token_offset = err_details.token.start - source_line_start;
    const source_line = err_details.token.getLine(source, source_line_start);
    if (err_details.err == .string_literal_too_long) {
        const before_slice = source_line[0..@min(source_line.len, token_offset + 16)];
        try writeSourceSlice(writer, before_slice);
        colors.set(writer, .dim);
        try writer.writeAll("<...truncated...>");
        colors.set(writer, .reset);
    } else {
        try writeSourceSlice(writer, source_line);
    }
    try writer.writeByte('\n');

    colors.set(writer, .green);
    try writer.writeByteNTimes(' ', token_offset);
    try writer.writeByte('^');
    try writer.writeByte('\n');
    colors.set(writer, .reset);

    if (source_mappings) |mappings| {
        const corresponding_span = mappings.get(err_details.token.line_number);
        const corresponding_file = mappings.files.get(corresponding_span.filename_offset);

        colors.set(writer, .bold);
        try writer.print("{s}:{d}:{d}: ", .{ corresponding_file, corresponding_span.start_line, 1 });
        colors.set(writer, .cyan);
        try writer.writeAll("note: ");
        colors.set(writer, .reset);
        colors.set(writer, .bold);
        try writer.writeAll("this line originated from line");
        if (corresponding_span.start_line != corresponding_span.end_line) {
            try writer.print("s {}-{}", .{ corresponding_span.start_line, corresponding_span.end_line });
        } else {
            try writer.print(" {}", .{corresponding_span.start_line});
        }
        try writer.print(" of file '{s}'\n", .{corresponding_file});
        colors.set(writer, .reset);

        // Don't print the originating line for this error, we know it's really long
        if (err_details.err == .string_literal_too_long) return;

        if (cwd.openFile(corresponding_file, .{})) |file| {
            var buffered_reader = std.io.bufferedReader(file.reader());
            writeLinesFromStream(writer, buffered_reader.reader(), corresponding_span.start_line, corresponding_span.end_line) catch |err| switch (err) {
                error.LinesNotFound => {
                    colors.set(writer, .red);
                    try writer.writeAll(" | ");
                    colors.set(writer, .dim);
                    try writer.print("unable to print line(s) from file: {s}\n", .{@errorName(err)});
                    colors.set(writer, .reset);
                },
                else => |e| return e,
            };
            try writer.writeByte('\n');
        } else |err| {
            colors.set(writer, .red);
            try writer.writeAll(" | ");
            colors.set(writer, .dim);
            try writer.print("unable to print line(s) from file: {s}\n", .{@errorName(err)});
            colors.set(writer, .reset);
        }
    }
}

fn writeSourceSlice(writer: anytype, slice: []const u8) !void {
    for (slice) |c| try writeSourceByte(writer, c);
}

inline fn writeSourceByte(writer: anytype, byte: u8) !void {
    switch (byte) {
        '\x00'...'\x08', '\x0E'...'\x1F', '\x7F' => try writer.writeAll("�"),
        // \r is seemingly ignored by the RC compiler so skipping it when printing source lines
        // could help avoid confusing output (e.g. RC\rDATA if printed verbatim would show up
        // in the console as DATA but the compiler reads it as RCDATA)
        //
        // NOTE: This is irrelevant when using the clang preprocessor, because unpaired \r
        //       characters get converted to \n, but may become relevant if another
        //       preprocessor is used instead.
        '\r' => {},
        '\t', '\x0B', '\x0C' => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    }
}

pub fn writeLinesFromStream(writer: anytype, input: anytype, start_line: usize, end_line: usize) !void {
    var line_num: usize = 1;
    while (try readByteOrEof(input)) |byte| {
        switch (byte) {
            '\n' => {
                if (line_num >= start_line) try writeSourceByte(writer, byte);
                if (line_num == end_line) return;
                line_num += 1;
            },
            else => {
                if (line_num >= start_line) try writeSourceByte(writer, byte);
            },
        }
    }
    if (line_num != end_line) {
        return error.LinesNotFound;
    }
}

pub fn readByteOrEof(reader: anytype) !?u8 {
    return reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
}
