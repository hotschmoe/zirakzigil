# smallest adapter changes to compile on 0.16.0 (measurement artifact; not part of the hook metric)
a=src/zv_air/adapter.zig
sed -i 's/@backingInt/@intFromEnum/g; s/@fromBackingInt(@intCast(\(.*\)))/@enumFromInt(\1)/' $a
sed -i 's/^    fn typeId(c: \*Ctx, ty: Type) Error!TypeId {$/    fn typeId(c: *Ctx, ty_or_ref: anytype) Error!TypeId {\n        const ty: Type = if (@TypeOf(ty_or_ref) == Type) ty_or_ref else ty_or_ref.toType();/' $a
sed -i 's/c\.typeId(\.fromInterned(/c.typeId(Type.fromInterned(/; s/ty\.fmt(c\.zcu)/ty.fmt(.{ .zcu = c.zcu, .tid = .main })/' $a
sed -i 's/ \.div_ceil,//' $a
for t in div_ceil_optimized array_to_vector error_cast error_from_int int_from_error int_from_ptr ptr_cast ptr_from_int union_from_enum spirv_runtime_array_len bit_cast_safe; do
    sed -i "s/, \.$t\b//; s/\.$t, //" $a
done
sed -i 's/\.agg_field_val/.struct_field_val/; s/\.int_cast_safe/.intcast_safe/; s/\.int_cast/.intcast/; s/\.bit_cast/.bitcast/' $a
sed -i 's/\.bit_and, \.bit_or, \.xor,/.bit_and, .bit_or, .bool_and, .bool_or, .xor,/' $a
sed -i 's/data\.ty_pl\.ty\.arrayLen/data.ty_pl.ty.toType().arrayLen/' $a
sed -i 's/fmtValue(c\.zcu)/fmtValue(.{ .zcu = c.zcu, .tid = .main })/' $a
