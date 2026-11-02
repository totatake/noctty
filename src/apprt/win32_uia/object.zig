//! COM identity thunks for embedded interfaces. Providers retain their own
//! interface eligibility and final-release policy; all interfaces share one
//! object reference count and recover the owner by the named field offset.
const std = @import("std");
const com = @import("com.zig");

pub fn ComObject(
    comptime Owner: type,
    comptime query: fn (*Owner, *const com.GUID, *?*anyopaque) com.HRESULT,
    comptime release: fn (*Owner) u32,
) type {
    return struct {
        pub fn Interface(comptime field: []const u8) type {
            const I = @FieldType(Owner, field);
            return struct {
                pub fn QueryInterface(p: *I, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
                    return query(@fieldParentPtr(field, p), iid, out);
                }

                pub fn AddRef(p: *I) callconv(.winapi) u32 {
                    const self: *Owner = @fieldParentPtr(field, p);
                    return self.refcount.fetchAdd(1, .monotonic) + 1;
                }

                pub fn Release(p: *I) callconv(.winapi) u32 {
                    return release(@fieldParentPtr(field, p));
                }
            };
        }
    };
}

/// The final-release policy of a provider that holds no other references:
/// the last `Release` frees the provider through its own allocator.
pub fn destroyOnLastRelease(comptime Owner: type) fn (*Owner) u32 {
    return struct {
        fn release(self: *Owner) u32 {
            const previous = self.refcount.fetchSub(1, .acq_rel);
            if (previous == 1) {
                self.alloc.destroy(self);
                return 0;
            }
            return previous - 1;
        }
    }.release;
}

/// Each property query transfers a fresh BSTR to its caller.
pub fn frameworkId(out: *com.VARIANT) com.HRESULT {
    out.* = com.VARIANT.empty();
    const value = com.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("Win32")) orelse
        return com.E_OUTOFMEMORY;
    out.* = com.VARIANT.fromBstr(value);
    return com.S_OK;
}

pub fn hostProvider(hwnd: com.HWND, out: *?*com.IRawElementProviderSimple) com.HRESULT {
    out.* = null;
    return com.UiaHostProviderFromHwnd(hwnd, out);
}

pub fn runtimeId(values: []const i32, out: *?*com.SAFEARRAY) com.HRESULT {
    out.* = null;
    const count = std.math.cast(u32, values.len) orelse return com.E_OUTOFMEMORY;
    const array = com.SafeArrayCreateVector(com.VT_I4, 0, count) orelse return com.E_OUTOFMEMORY;
    for (values, 0..) |value, slot| {
        var element = value;
        var index: i32 = @intCast(slot);
        if (com.SafeArrayPutElement(array, &index, &element) != com.S_OK) {
            _ = com.SafeArrayDestroy(array);
            return com.E_OUTOFMEMORY;
        }
    }
    out.* = array;
    return com.S_OK;
}

test "framework ID property transfers independent BSTR ownership" {
    var first = com.VARIANT.empty();
    var second = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, frameworkId(&first));
    defer _ = com.VariantClear(&first);
    try std.testing.expectEqual(com.S_OK, frameworkId(&second));
    defer _ = com.VariantClear(&second);
    try std.testing.expect(first.value.bstr != second.value.bstr);
    try std.testing.expectEqual(@as(u32, 5), com.SysStringLen(first.value.bstr));
    try std.testing.expectEqualStrings("Win32", &.{
        @intCast(first.value.bstr.?[0]), @intCast(first.value.bstr.?[1]),
        @intCast(first.value.bstr.?[2]), @intCast(first.value.bstr.?[3]),
        @intCast(first.value.bstr.?[4]),
    });
}

test "runtime ID preserves all signed identity components" {
    var array: ?*com.SAFEARRAY = null;
    const values = [_]i32{ com.UiaAppendRuntimeId, -1, 42 };
    try std.testing.expectEqual(com.S_OK, runtimeId(&values, &array));
    defer _ = com.SafeArrayDestroy(array.?);
    for (values, 0..) |expected, slot| {
        var index: i32 = @intCast(slot);
        var actual: i32 = 0;
        try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(array.?, &index, &actual));
        try std.testing.expectEqual(expected, actual);
    }
}

test "embedded COM interfaces share identity and balanced references" {
    const Fixture = struct {
        base: com.IRawElementProviderSimple = undefined,
        invoke: com.IInvokeProvider = undefined,
        refcount: std.atomic.Value(u32) = .init(1),
        enabled: bool = true,

        fn query(self: *@This(), iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
            out.* = null;
            if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&com.IID_IUnknown))) {
                out.* = @ptrCast(&self.base);
            } else if (self.enabled and std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&com.IID_IInvokeProvider))) {
                out.* = @ptrCast(&self.invoke);
            } else return com.E_NOINTERFACE;
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }

        fn release(self: *@This()) u32 {
            return self.refcount.fetchSub(1, .acq_rel) - 1;
        }
    };
    const Object = ComObject(Fixture, Fixture.query, Fixture.release);
    const Simple = Object.Interface("base");
    const Invoke = Object.Interface("invoke");
    try std.testing.expect(@offsetOf(Fixture, "invoke") != 0);
    var owner: Fixture = .{};
    var result: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, Simple.QueryInterface(&owner.base, &com.IID_IInvokeProvider, &result));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&owner.invoke)), result);
    try std.testing.expectEqual(com.S_OK, Invoke.QueryInterface(&owner.invoke, &com.IID_IUnknown, &result));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&owner.base)), result);
    try std.testing.expectEqual(@as(u32, 4), Invoke.AddRef(&owner.invoke));
    try std.testing.expectEqual(@as(u32, 3), Simple.Release(&owner.base));
    try std.testing.expectEqual(@as(u32, 2), Invoke.Release(&owner.invoke));
    owner.enabled = false;
    try std.testing.expectEqual(com.E_NOINTERFACE, Invoke.QueryInterface(&owner.invoke, &com.IID_IInvokeProvider, &result));
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
    try std.testing.expectEqual(@as(u32, 1), Invoke.Release(&owner.invoke));
    try std.testing.expectEqual(@as(u32, 0), Simple.Release(&owner.base));
}
