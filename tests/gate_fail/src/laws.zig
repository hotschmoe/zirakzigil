const zv = @import("zv");
const lib = @import("root.zig");

pub const laws = struct {
    pub fn exercisedSaturates(x: u8) bool {
        return lib.exercised(x) >= x;
    }
};

test "laws hold" {
    try zv.checkLaws(laws, .{ .iterations = 100, .seed = 1 });
}
