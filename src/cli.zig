const std = @import("std");
const CodePage = @import("code_pages.zig").CodePage;
const lang = @import("lang.zig");
const utils = @import("utils.zig");
const res = @import("res.zig");
const Allocator = std.mem.Allocator;
const lex = @import("lex.zig");

/// This is what /SL 100 will set the maximum string literal length to
pub const max_string_literal_length_100_percent = 8192;

pub const Diagnostics = struct {
    errors: std.ArrayListUnmanaged(ErrorDetails) = .{},
    allocator: Allocator,

    pub const ErrorDetails = struct {
        arg_index: usize,
        arg_span: ArgSpan = .{},
        msg: std.ArrayListUnmanaged(u8) = .{},
        type: Type = .err,
        print_args: bool = true,

        pub const Type = enum { err, warning, note };
        pub const ArgSpan = struct {
            point_at_next_arg: bool = false,
            name_offset: usize = 0,
            prefix_len: usize = 0,
            value_offset: usize = 0,
        };
    };

    pub fn init(allocator: Allocator) Diagnostics {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.errors.items) |*details| {
            details.msg.deinit(self.allocator);
        }
        self.errors.deinit(self.allocator);
    }

    pub fn append(self: *Diagnostics, error_details: ErrorDetails) !void {
        try self.errors.append(self.allocator, error_details);
    }

    pub fn renderToStdErr(self: *Diagnostics, args: []const []const u8) void {
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
        self.renderToWriter(args, stderr, colors) catch return;
    }

    pub fn renderToWriter(self: *Diagnostics, args: []const []const u8, writer: anytype, colors: utils.Colors) !void {
        for (self.errors.items) |err_details| {
            try renderErrorMessage(writer, colors, err_details, args);
        }
    }

    pub fn hasError(self: *const Diagnostics) bool {
        for (self.errors.items) |err| {
            if (err.type == .err) return true;
        }
        return false;
    }
};

pub const Options = struct {
    allocator: Allocator,
    input_filename: []const u8 = &[_]u8{},
    output_filename: []const u8 = &[_]u8{},
    extra_include_paths: std.ArrayListUnmanaged([]const u8) = .{},
    ignore_include_env_var: bool = false,
    preprocess: bool = true,
    default_language_id: ?u16 = null,
    default_code_page: ?CodePage = null,
    verbose: bool = false,
    symbols: std.StringArrayHashMapUnmanaged(SymbolAction) = .{},
    null_terminate_string_table_strings: bool = false,
    max_string_literal_codepoints: u15 = lex.default_max_string_literal_codepoints,
    silent_duplicate_control_ids: bool = false,
    warn_instead_of_error_on_invalid_code_page: bool = false,

    pub const SymbolAction = enum { define, undefine };

    /// Does not check that identifier contains only valid characters
    pub fn define(self: *Options, identifier: []const u8) !void {
        // If the identifier is already in the symbols, then there's nothing
        // we need to do:
        // - If the symbol is already defined, then we don't need to do anything.
        // - If the symbol is undefined, then that always takes precedence so
        //   we shouldn't change anything.
        if (self.symbols.contains(identifier)) return;
        var duped_key = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(duped_key);
        try self.symbols.put(self.allocator, duped_key, .define);
    }

    /// Does not check that identifier contains only valid characters
    pub fn undefine(self: *Options, identifier: []const u8) !void {
        if (self.symbols.getPtr(identifier)) |action| {
            action.* = .undefine;
            return;
        }
        var duped_key = try self.allocator.dupe(u8, identifier);
        errdefer self.allocator.free(duped_key);
        try self.symbols.put(self.allocator, duped_key, .undefine);
    }

    pub fn deinit(self: *Options) void {
        for (self.extra_include_paths.items) |extra_include_path| {
            self.allocator.free(extra_include_path);
        }
        self.extra_include_paths.deinit(self.allocator);
        self.allocator.free(self.input_filename);
        self.allocator.free(self.output_filename);
        for (self.symbols.keys()) |name| {
            self.allocator.free(name);
        }
        self.symbols.deinit(self.allocator);
    }

    pub fn dumpVerbose(self: *const Options, writer: anytype) !void {
        try writer.print("Input filename: {s}\n", .{self.input_filename});
        try writer.print("Output filename: {s}\n", .{self.output_filename});
        if (self.extra_include_paths.items.len > 0) {
            try writer.writeAll(" Extra include paths:\n");
            for (self.extra_include_paths.items) |extra_include_path| {
                try writer.print("  \"{s}\"\n", .{extra_include_path});
            }
        }
        if (self.ignore_include_env_var) {
            try writer.writeAll(" The INCLUDE environment variable will be ignored\n");
        }
        if (!self.preprocess) {
            try writer.writeAll(" The preprocessor will not be invoked\n");
        }
        if (self.symbols.count() > 0) {
            try writer.writeAll(" Symbols:\n");
            var it = self.symbols.iterator();
            while (it.next()) |symbol| {
                try writer.print("  {s} {s}\n", .{ switch (symbol.value_ptr.*) {
                    .define => "#define",
                    .undefine => "#undef",
                }, symbol.key_ptr.* });
            }
        }

        const language_id = self.default_language_id orelse res.Language.default;
        const language_name = language_name: {
            if (std.meta.intToEnum(lang.LanguageId, language_id)) |lang_enum_val| {
                break :language_name @tagName(lang_enum_val);
            } else |_| {}
            if (language_id == lang.LOCALE_CUSTOM_UNSPECIFIED) {
                break :language_name "LOCALE_CUSTOM_UNSPECIFIED";
            }
            break :language_name "<UNKNOWN>";
        };
        try writer.print("Default language: {s} (id=0x{x})\n", .{ language_name, language_id });

        const code_page = self.default_code_page orelse .windows1252;
        try writer.print("Default codepage: {s} (id={})\n", .{ @tagName(code_page), @enumToInt(code_page) });
    }
};

pub const Arg = struct {
    prefix: enum { long, short, slash },
    name_offset: usize,
    full: []const u8,

    pub fn fromString(str: []const u8) ?@This() {
        if (std.mem.startsWith(u8, str, "--")) {
            return .{ .prefix = .long, .name_offset = 2, .full = str };
        } else if (std.mem.startsWith(u8, str, "-")) {
            return .{ .prefix = .short, .name_offset = 1, .full = str };
        } else if (std.mem.startsWith(u8, str, "/")) {
            return .{ .prefix = .slash, .name_offset = 1, .full = str };
        }
        return null;
    }

    pub fn prefixSlice(self: Arg) []const u8 {
        return self.full[0..(if (self.prefix == .long) 2 else 1)];
    }

    pub fn name(self: Arg) []const u8 {
        return self.full[self.name_offset..];
    }

    pub fn optionWithoutPrefix(self: Arg, option_len: usize) []const u8 {
        return self.name()[0..option_len];
    }

    pub fn missingSpan(self: Arg) Diagnostics.ErrorDetails.ArgSpan {
        return .{
            .point_at_next_arg = true,
            .value_offset = 0,
            .name_offset = self.name_offset,
            .prefix_len = self.prefixSlice().len,
        };
    }

    pub const Value = struct {
        slice: []const u8,
        index_increment: u2 = 1,

        pub fn argSpan(self: Value, arg: Arg) Diagnostics.ErrorDetails.ArgSpan {
            const prefix_len = arg.prefixSlice().len;
            switch (self.index_increment) {
                1 => return .{
                    .value_offset = @ptrToInt(self.slice.ptr) - @ptrToInt(arg.full.ptr),
                    .prefix_len = prefix_len,
                    .name_offset = arg.name_offset,
                },
                2 => return .{
                    .point_at_next_arg = true,
                    .prefix_len = prefix_len,
                    .name_offset = arg.name_offset,
                },
                else => unreachable,
            }
        }

        pub fn index(self: Value, arg_index: usize) usize {
            if (self.index_increment == 2) return arg_index + 1;
            return arg_index;
        }
    };

    pub fn value(self: Arg, option_len: usize, index: usize, args: []const []const u8) error{MissingValue}!Value {
        const rest = self.full[self.name_offset + option_len ..];
        if (rest.len > 0) return .{ .slice = rest };
        if (index + 1 >= args.len) return error.MissingValue;
        return .{ .slice = args[index + 1], .index_increment = 2 };
    }

    pub const Context = struct {
        index: usize,
        arg: Arg,
        value: Value,
    };
};

pub const ParseError = error{ParseError} || Allocator.Error;

pub fn parse(allocator: Allocator, args: []const []const u8, diagnostics: *Diagnostics) ParseError!Options {
    var options = Options{ .allocator = allocator };
    errdefer options.deinit();

    var output_filename: ?[]const u8 = null;
    var output_filename_context: Arg.Context = undefined;

    var arg_i: usize = 1; // start at 1 to skip past the exe name
    next_arg: while (arg_i < args.len) {
        var arg = Arg.fromString(args[arg_i]) orelse break;
        // -- on its own ends arg parsing
        if (arg.name().len == 0 and arg.prefix == .long) {
            arg_i += 1;
            break;
        }

        while (arg.name().len > 0) {
            const arg_name = arg.name();
            // Note: These cases should be in order from longest to shortest, since
            //       shorter options that are a substring of a longer one could make
            //       the longer option's branch unreachable.
            if (std.ascii.startsWithIgnoreCase(arg_name, "no-preprocess")) {
                options.preprocess = false;
                arg.name_offset += "no-preprocess".len;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "nologo")) {
                // No-op, we don't display any 'logo' to suppress
                arg.name_offset += "nologo".len;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "fo")) {
                const value = arg.value(2, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing output path after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                output_filename_context = .{ .index = arg_i, .arg = arg, .value = value };
                output_filename = value.slice;
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "sl")) {
                const value = arg.value(2, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing language tag after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const percent_str = value.slice;
                const percent: u32 = parsePercent(percent_str) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid percent format '{s}'", .{percent_str});
                    try diagnostics.append(err_details);
                    var note_details = Diagnostics.ErrorDetails{ .type = .note, .print_args = false, .arg_index = arg_i };
                    var note_writer = note_details.msg.writer(allocator);
                    try note_writer.writeAll("string length percent must be an integer between 1 and 100 (inclusive)");
                    try diagnostics.append(note_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                if (percent == 0 or percent > 100) {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("percent out of range: {} (parsed from '{s}')", .{ percent, percent_str });
                    try diagnostics.append(err_details);
                    var note_details = Diagnostics.ErrorDetails{ .type = .note, .print_args = false, .arg_index = arg_i };
                    var note_writer = note_details.msg.writer(allocator);
                    try note_writer.writeAll("string length percent must be an integer between 1 and 100 (inclusive)");
                    try diagnostics.append(note_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                }
                const percent_float = @intToFloat(f32, percent) / 100;
                options.max_string_literal_codepoints = @floatToInt(u15, percent_float * max_string_literal_length_100_percent);
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "ln")) {
                const value = arg.value(2, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing language tag after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(2) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const tag = value.slice;
                options.default_language_id = lang.tagToInt(tag) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid language tag: {s}", .{tag});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                if (options.default_language_id.? == lang.LOCALE_CUSTOM_UNSPECIFIED) {
                    var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("language tag '{s}' does not have an assigned ID so it will be resolved to LOCALE_CUSTOM_UNSPECIFIED (id=0x{x})", .{ tag, lang.LOCALE_CUSTOM_UNSPECIFIED });
                    try diagnostics.append(err_details);
                }
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "l")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing language ID after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const num_str = value.slice;
                options.default_language_id = lang.parseInt(num_str) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid language ID: {s}", .{num_str});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "c")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing code page ID after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const num_str = value.slice;
                const code_page_id = std.fmt.parseUnsigned(u16, num_str, 10) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("invalid code page ID: {s}", .{num_str});
                    try diagnostics.append(err_details);
                    arg_i += value.index_increment;
                    continue :next_arg;
                };
                options.default_code_page = CodePage.getByIdentifierEnsureSupported(code_page_id) catch |err| switch (err) {
                    error.InvalidCodePage => {
                        var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                        var msg_writer = err_details.msg.writer(allocator);
                        try msg_writer.print("invalid or unknown code page ID: {}", .{code_page_id});
                        try diagnostics.append(err_details);
                        arg_i += value.index_increment;
                        continue :next_arg;
                    },
                    error.UnsupportedCodePage => {
                        var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                        var msg_writer = err_details.msg.writer(allocator);
                        try msg_writer.print("unsupported code page: {s} (id={})", .{
                            @tagName(CodePage.getByIdentifier(code_page_id) catch unreachable),
                            code_page_id,
                        });
                        try diagnostics.append(err_details);
                        arg_i += value.index_increment;
                        continue :next_arg;
                    },
                };
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "v")) {
                options.verbose = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "x")) {
                options.ignore_include_env_var = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "i")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing include path after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const path = value.slice;
                const duped = try allocator.dupe(u8, path);
                errdefer allocator.free(duped);
                try options.extra_include_paths.append(options.allocator, duped);
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "r")) {
                // From https://learn.microsoft.com/en-us/windows/win32/menurc/using-rc-the-rc-command-line-
                // "Ignored. Provided for compatibility with existing makefiles."
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "n")) {
                options.null_terminate_string_table_strings = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "y")) {
                options.silent_duplicate_control_ids = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "w")) {
                options.warn_instead_of_error_on_invalid_code_page = true;
                arg.name_offset += 1;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "d")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing symbol to define after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const symbol = value.slice;
                if (isValidIdentifier(symbol)) {
                    try options.define(symbol);
                } else {
                    var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("symbol \"{s}\" is not a valid identifier and therefore cannot be defined", .{symbol});
                    try diagnostics.append(err_details);
                }
                arg_i += value.index_increment;
                continue :next_arg;
            } else if (std.ascii.startsWithIgnoreCase(arg_name, "u")) {
                const value = arg.value(1, arg_i, args) catch {
                    var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = arg.missingSpan() };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("missing symbol to undefine after {s}{s} option", .{ arg.prefixSlice(), arg.optionWithoutPrefix(1) });
                    try diagnostics.append(err_details);
                    arg_i += 1;
                    break :next_arg;
                };
                const symbol = value.slice;
                if (isValidIdentifier(symbol)) {
                    try options.undefine(symbol);
                } else {
                    var err_details = Diagnostics.ErrorDetails{ .type = .warning, .arg_index = arg_i, .arg_span = value.argSpan(arg) };
                    var msg_writer = err_details.msg.writer(allocator);
                    try msg_writer.print("symbol \"{s}\" is not a valid identifier and therefore cannot be undefined", .{symbol});
                    try diagnostics.append(err_details);
                }
                arg_i += value.index_increment;
                continue :next_arg;
            } else {
                var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i, .arg_span = .{
                    .name_offset = arg.name_offset,
                    .prefix_len = arg.prefixSlice().len,
                } };
                var msg_writer = err_details.msg.writer(allocator);
                try msg_writer.print("invalid option: {s}{s}", .{ arg.prefixSlice(), arg.name() });
                try diagnostics.append(err_details);
                arg_i += 1;
                continue :next_arg;
            }
        } else {
            // The while loop exited via its conditional, meaning we are done with
            // the current arg and can move on the the next
            arg_i += 1;
            continue;
        }
    }

    var positionals = args[arg_i..];

    if (positionals.len < 1) {
        var err_details = Diagnostics.ErrorDetails{ .print_args = false, .arg_index = arg_i };
        var msg_writer = err_details.msg.writer(allocator);
        try msg_writer.writeAll("missing input filename");
        try diagnostics.append(err_details);
        // This is a fatal enough problem to justify an early return, since
        // things after this rely on the value of the input filename.
        return error.ParseError;
    }
    options.input_filename = try allocator.dupe(u8, positionals[0]);

    if (positionals.len > 1) {
        if (output_filename != null) {
            var err_details = Diagnostics.ErrorDetails{ .arg_index = arg_i + 1 };
            var msg_writer = err_details.msg.writer(allocator);
            try msg_writer.writeAll("output filename already specified");
            try diagnostics.append(err_details);
            var note_details = Diagnostics.ErrorDetails{
                .type = .note,
                .arg_index = output_filename_context.value.index(output_filename_context.index),
                .arg_span = output_filename_context.value.argSpan(output_filename_context.arg),
            };
            var note_writer = note_details.msg.writer(allocator);
            try note_writer.writeAll("output filename previously specified here");
            try diagnostics.append(note_details);
        } else {
            output_filename = positionals[1];
        }
    }
    if (output_filename == null) {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        if (std.fs.path.dirname(options.input_filename)) |dirname| {
            var end_pos = dirname.len;
            // We want to ensure that we write a path separator at the end, so if the dirname
            // doesn't end with a path sep then include the char after the dirname
            // which must be a path sep.
            if (!std.fs.path.isSep(dirname[dirname.len - 1])) end_pos += 1;
            try buf.appendSlice(options.input_filename[0..end_pos]);
        }
        try buf.appendSlice(std.fs.path.stem(options.input_filename));
        try buf.appendSlice(".res");

        options.output_filename = try buf.toOwnedSlice();
    } else {
        options.output_filename = try allocator.dupe(u8, output_filename.?);
    }

    if (diagnostics.hasError()) {
        return error.ParseError;
    }

    return options;
}

/// Returns true if the str is a valid C identifier for use in a #define/#undef macro
pub fn isValidIdentifier(str: []const u8) bool {
    for (str, 0..) |c, i| switch (c) {
        '0'...'9' => if (i == 0) return false,
        'a'...'z', 'A'...'Z', '_' => {},
        else => return false,
    };
    return true;
}

/// This function is specific to how the Win32 RC command line interprets
/// max string literal length percent.
/// - Wraps on overflow of u32
/// - Stops parsing on any invalid hexadecimal digits
/// - Errors if a digit is not the first char
/// - `-` (negative) prefix is allowed
pub fn parsePercent(str: []const u8) error{InvalidFormat}!u32 {
    var result: u32 = 0;
    const radix: u8 = 10;
    var buf = str;

    const Prefix = enum { none, minus };
    var prefix: Prefix = .none;
    switch (buf[0]) {
        '-' => {
            prefix = .minus;
            buf = buf[1..];
        },
        else => {},
    }

    for (buf, 0..) |c, i| {
        const digit = switch (c) {
            // On invalid digit for the radix, just stop parsing but don't fail
            '0'...'9' => std.fmt.charToDigit(c, radix) catch break,
            else => {
                // First digit must be valid
                if (i == 0) {
                    return error.InvalidFormat;
                }
                break;
            },
        };

        if (result != 0) {
            result *%= radix;
        }
        result +%= digit;
    }

    switch (prefix) {
        .none => {},
        .minus => result = 0 -% result,
    }

    return result;
}

test parsePercent {
    try std.testing.expectEqual(@as(u32, 16), try parsePercent("16"));
    try std.testing.expectEqual(@as(u32, 0), try parsePercent("0x1A"));
    try std.testing.expectEqual(@as(u32, 0x1), try parsePercent("1zzzz"));
    try std.testing.expectEqual(@as(u32, 0xffffffff), try parsePercent("-1"));
    try std.testing.expectEqual(@as(u32, 0xfffffff0), try parsePercent("-16"));
    try std.testing.expectEqual(@as(u32, 1), try parsePercent("4294967297"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("--1"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("ha"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("¹"));
    try std.testing.expectError(error.InvalidFormat, parsePercent("~1"));
}

pub fn renderErrorMessage(writer: anytype, colors: utils.Colors, err_details: Diagnostics.ErrorDetails, args: []const []const u8) !void {
    colors.set(writer, .dim);
    try writer.writeAll("<cli>");
    colors.set(writer, .reset);
    colors.set(writer, .bold);
    try writer.writeAll(": ");
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
    try writer.writeAll(err_details.msg.items);
    try writer.writeByte('\n');
    colors.set(writer, .reset);

    if (!err_details.print_args) {
        try writer.writeByte('\n');
        return;
    }

    colors.set(writer, .dim);
    const prefix = " ... ";
    try writer.writeAll(prefix);
    colors.set(writer, .reset);

    const arg_with_name = args[err_details.arg_index];

    if (err_details.arg_span.prefix_len == err_details.arg_span.name_offset) {
        try writer.writeAll(arg_with_name);
    } else {
        try writer.writeAll(arg_with_name[0..err_details.arg_span.prefix_len]);
        colors.set(writer, .dim);
        try writer.writeAll(arg_with_name[err_details.arg_span.prefix_len..err_details.arg_span.name_offset]);
        colors.set(writer, .reset);
        try writer.writeAll(arg_with_name[err_details.arg_span.name_offset..]);
    }
    var next_arg_len: usize = 0;
    if (err_details.arg_span.point_at_next_arg and err_details.arg_index + 1 < args.len) {
        const next_arg = args[err_details.arg_index + 1];
        try writer.writeByte(' ');
        try writer.writeAll(next_arg);
        next_arg_len = next_arg.len;
    }

    const last_shown_arg_index = if (err_details.arg_span.point_at_next_arg) err_details.arg_index + 1 else err_details.arg_index;
    if (last_shown_arg_index + 1 < args.len) {
        colors.set(writer, .dim);
        try writer.writeAll(" ...");
        colors.set(writer, .reset);
    }
    try writer.writeByte('\n');

    colors.set(writer, .green);
    try writer.writeByteNTimes(' ', prefix.len);
    try writer.writeByteNTimes('~', err_details.arg_span.prefix_len);
    try writer.writeByteNTimes(' ', err_details.arg_span.name_offset - err_details.arg_span.prefix_len);
    if (!err_details.arg_span.point_at_next_arg and err_details.arg_span.value_offset == 0) {
        try writer.writeByte('^');
        try writer.writeByteNTimes('~', arg_with_name.len - err_details.arg_span.name_offset - 1);
    } else if (err_details.arg_span.value_offset > 0) {
        try writer.writeByteNTimes('~', err_details.arg_span.value_offset - err_details.arg_span.name_offset);
        try writer.writeByte('^');
        try writer.writeByteNTimes('~', arg_with_name.len - err_details.arg_span.value_offset - 1);
    } else if (err_details.arg_span.point_at_next_arg) {
        try writer.writeByteNTimes('~', arg_with_name.len - err_details.arg_span.name_offset + 1);
        try writer.writeByte('^');
        if (next_arg_len > 0) {
            try writer.writeByteNTimes('~', next_arg_len - 1);
        }
    }
    try writer.writeByte('\n');
    colors.set(writer, .reset);
}

fn testParse(args: []const []const u8) !Options {
    return (try testParseOutput(args, "")).?;
}

fn testParseWarning(args: []const []const u8, expected_output: []const u8) !Options {
    return (try testParseOutput(args, expected_output)).?;
}

fn testParseError(args: []const []const u8, expected_output: []const u8) !void {
    var maybe_options = try testParseOutput(args, expected_output);
    if (maybe_options != null) {
        std.debug.print("expected error, got options: {}\n", .{maybe_options.?});
        maybe_options.?.deinit();
        return error.TestExpectedError;
    }
}

fn testParseOutput(args: []const []const u8, expected_output: []const u8) !?Options {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    var options = parse(std.testing.allocator, args, &diagnostics) catch |err| switch (err) {
        error.ParseError => {
            try diagnostics.renderToWriter(args, output.writer(), .no_color);
            try std.testing.expectEqualStrings(expected_output, output.items);
            return null;
        },
        else => |e| return e,
    };
    errdefer options.deinit();

    try diagnostics.renderToWriter(args, output.writer(), .no_color);
    try std.testing.expectEqualStrings(expected_output, output.items);
    return options;
}

test "parse errors: basic" {
    try testParseError(&.{ "foo.exe", "/ln" },
        \\<cli>: error: missing language tag after /ln option
        \\ ... /ln
        \\     ~~~~^
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "-vln" },
        \\<cli>: error: missing language tag after -ln option
        \\ ... -vln
        \\     ~ ~~~^
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "/_not-an-option" },
        \\<cli>: error: invalid option: /_not-an-option
        \\ ... /_not-an-option
        \\     ~^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "-_not-an-option" },
        \\<cli>: error: invalid option: -_not-an-option
        \\ ... -_not-an-option
        \\     ~^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "--_not-an-option" },
        \\<cli>: error: invalid option: --_not-an-option
        \\ ... --_not-an-option
        \\     ~~^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "/v_not-an-option" },
        \\<cli>: error: invalid option: /_not-an-option
        \\ ... /v_not-an-option
        \\     ~ ^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "-v_not-an-option" },
        \\<cli>: error: invalid option: -_not-an-option
        \\ ... -v_not-an-option
        \\     ~ ^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "--v_not-an-option" },
        \\<cli>: error: invalid option: --_not-an-option
        \\ ... --v_not-an-option
        \\     ~~ ^~~~~~~~~~~~~~
        \\<cli>: error: missing input filename
        \\
        \\
    );
}

test "parse errors: /ln" {
    try testParseError(&.{ "foo.exe", "/ln", "invalid", "foo.rc" },
        \\<cli>: error: invalid language tag: invalid
        \\ ... /ln invalid ...
        \\     ~~~~^~~~~~~
        \\
    );
    try testParseError(&.{ "foo.exe", "/lninvalid", "foo.rc" },
        \\<cli>: error: invalid language tag: invalid
        \\ ... /lninvalid ...
        \\     ~~~^~~~~~~
        \\
    );
}

test "parse: options" {
    {
        var options = try testParse(&.{ "foo.exe", "/v", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqualStrings("foo.rc", options.input_filename);
        try std.testing.expectEqualStrings("foo.res", options.output_filename);
    }
    {
        var options = try testParse(&.{ "foo.exe", "/vx", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_filename);
        try std.testing.expectEqualStrings("foo.res", options.output_filename);
    }
    {
        var options = try testParse(&.{ "foo.exe", "/xv", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_filename);
        try std.testing.expectEqualStrings("foo.res", options.output_filename);
    }
    {
        var options = try testParse(&.{ "foo.exe", "/xvFObar.res", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(true, options.verbose);
        try std.testing.expectEqual(true, options.ignore_include_env_var);
        try std.testing.expectEqualStrings("foo.rc", options.input_filename);
        try std.testing.expectEqualStrings("bar.res", options.output_filename);
    }
}

test "parse: define and undefine" {
    {
        var options = try testParse(&.{ "foo.exe", "/dfoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.define, action);
    }
    {
        var options = try testParse(&.{ "foo.exe", "/ufoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.undefine, action);
    }
    {
        // Once undefined, future defines are ignored
        var options = try testParse(&.{ "foo.exe", "/ufoo", "/dfoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.undefine, action);
    }
    {
        // Undefined always takes precedence
        var options = try testParse(&.{ "foo.exe", "/dfoo", "/ufoo", "/dfoo", "foo.rc" });
        defer options.deinit();

        const action = options.symbols.get("foo").?;
        try std.testing.expectEqual(Options.SymbolAction.undefine, action);
    }
    {
        // Warn + ignore invalid identifiers
        var options = try testParseWarning(
            &.{ "foo.exe", "/dfoo bar", "/u", "0leadingdigit", "foo.rc" },
            \\<cli>: warning: symbol "foo bar" is not a valid identifier and therefore cannot be defined
            \\ ... /dfoo bar ...
            \\     ~~^~~~~~~
            \\<cli>: warning: symbol "0leadingdigit" is not a valid identifier and therefore cannot be undefined
            \\ ... /u 0leadingdigit ...
            \\     ~~~^~~~~~~~~~~~~
            \\
            ,
        );
        defer options.deinit();

        try std.testing.expectEqual(@as(usize, 0), options.symbols.count());
    }
}

test "parse: /sl" {
    try testParseError(&.{ "foo.exe", "/sl", "0", "foo.rc" },
        \\<cli>: error: percent out of range: 0 (parsed from '0')
        \\ ... /sl 0 ...
        \\     ~~~~^
        \\<cli>: note: string length percent must be an integer between 1 and 100 (inclusive)
        \\
        \\
    );
    try testParseError(&.{ "foo.exe", "/sl", "abcd", "foo.rc" },
        \\<cli>: error: invalid percent format 'abcd'
        \\ ... /sl abcd ...
        \\     ~~~~^~~~
        \\<cli>: note: string length percent must be an integer between 1 and 100 (inclusive)
        \\
        \\
    );
    {
        var options = try testParse(&.{ "foo.exe", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, lex.default_max_string_literal_codepoints), options.max_string_literal_codepoints);
    }
    {
        var options = try testParse(&.{ "foo.exe", "/sl100", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, max_string_literal_length_100_percent), options.max_string_literal_codepoints);
    }
    {
        var options = try testParse(&.{ "foo.exe", "-SL33", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, 2703), options.max_string_literal_codepoints);
    }
    {
        var options = try testParse(&.{ "foo.exe", "/sl15", "foo.rc" });
        defer options.deinit();

        try std.testing.expectEqual(@as(u15, 1228), options.max_string_literal_codepoints);
    }
}
