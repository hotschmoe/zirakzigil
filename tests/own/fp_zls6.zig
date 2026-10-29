const std = @import("std");
const Node = struct { tag: u8 };
pub const Ast = struct {
    nodes: []const Node,
    errors: []const u32,

    // ziggy src/Ast.zig:139: `defer p.deinit(); return p.parse();`, parse hands the lists out with toOwnedSlice
    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Ast {
        var p: Parser = .{ .gpa = gpa };
        defer p.deinit();
        return p.parse();
    }
    pub fn deinit(ast: Ast, gpa: std.mem.Allocator) void {
        gpa.free(ast.nodes);
        gpa.free(ast.errors);
    }
    const Parser = struct {
        gpa: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        errors: std.ArrayList(u32) = .empty,
        fn deinit(p: *Parser) void {
            p.nodes.deinit(p.gpa);
            p.errors.deinit(p.gpa);
        }
        fn parse(p: *Parser) error{OutOfMemory}!Ast {
            try p.nodes.append(p.gpa, .{ .tag = 1 });
            return .{
                .nodes = try p.nodes.toOwnedSlice(p.gpa),
                .errors = try p.errors.toOwnedSlice(p.gpa),
            };
        }
    };
};
