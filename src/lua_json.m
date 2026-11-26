#import <Foundation/Foundation.h>
#include "lua.h"
#include "lauxlib.h"
#include <math.h>

static int g_json_null_sentinel = 0;
#define JSON_NULL_PTR ((void *)&g_json_null_sentinel)

static void push_objc_to_lua(lua_State *L, id obj) {
    if (!obj || obj == [NSNull null]) {
        lua_pushlightuserdata(L, JSON_NULL_PTR);
        return;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)obj dataUsingEncoding:NSUTF8StringEncoding];
        lua_pushlstring(L, (const char *)d.bytes, d.length);
        return;
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)obj) == CFBooleanGetTypeID()) {
            lua_pushboolean(L, [(NSNumber *)obj boolValue] ? 1 : 0);
        } else {
            double v = [(NSNumber *)obj doubleValue];
            lua_Integer iv = (lua_Integer)v;
            if ((double)iv == v && isfinite(v) && strcmp([(NSNumber *)obj objCType], "d") != 0 && strcmp([(NSNumber *)obj objCType], "f") != 0) {
                lua_pushinteger(L, iv);
            } else {
                lua_pushnumber(L, v);
            }
        }
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        lua_createtable(L, (int)arr.count, 0);
        for (NSUInteger i = 0; i < arr.count; i++) {
            push_objc_to_lua(L, arr[i]);
            lua_rawseti(L, -2, (lua_Integer)(i + 1));
        }
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        lua_createtable(L, 0, (int)dict.count);
        for (id key in dict) {
            if ([key isKindOfClass:[NSString class]]) {
                NSData *kd = [(NSString *)key dataUsingEncoding:NSUTF8StringEncoding];
                lua_pushlstring(L, (const char *)kd.bytes, kd.length);
                push_objc_to_lua(L, dict[key]);
                lua_rawset(L, -3);
            }
        }
        return;
    }
    lua_pushnil(L);
}

static id lua_to_objc(lua_State *L, int idx, int depth) {
    if (depth > 32) return [NSNull null];
    idx = lua_absindex(L, idx);
    int t = lua_type(L, idx);
    switch (t) {
        case LUA_TNIL:
            return [NSNull null];
        case LUA_TBOOLEAN:
            return lua_toboolean(L, idx) ? @YES : @NO;
        case LUA_TNUMBER: {
            if (lua_isinteger(L, idx)) {
                return @(lua_tointeger(L, idx));
            }
            double d = lua_tonumber(L, idx);
            if (!isfinite(d)) return [NSNull null];
            return @(d);
        }
        case LUA_TSTRING: {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            NSString *str = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
            return str ?: @"";
        }
        case LUA_TLIGHTUSERDATA:
            if (lua_touserdata(L, idx) == JSON_NULL_PTR) return [NSNull null];
            return [NSNull null];
        case LUA_TTABLE: {
            // Check if table is a contiguous 1..N array
            BOOL isArray = YES;
            lua_Integer totalKeys = 0;
            lua_Integer intCount = 0;
            lua_Integer maxIdx = 0;
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                totalKeys++;
                if (lua_type(L, -2) == LUA_TNUMBER && lua_isinteger(L, -2)) {
                    lua_Integer k = lua_tointeger(L, -2);
                    if (k >= 1) {
                        intCount++;
                        if (k > maxIdx) maxIdx = k;
                    } else {
                        isArray = NO;
                    }
                } else {
                    isArray = NO;
                }
                lua_pop(L, 1);
            }
            if (totalKeys == 0) {
                // Empty table -> JSON object {}
                return @{};
            }
            if (isArray && intCount == totalKeys && maxIdx == intCount) {
                NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)intCount];
                for (lua_Integer i = 1; i <= intCount; i++) {
                    lua_rawgeti(L, idx, i);
                    [arr addObject:lua_to_objc(L, -1, depth + 1)];
                    lua_pop(L, 1);
                }
                return arr;
            }
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                NSString *keyStr = nil;
                if (lua_type(L, -2) == LUA_TSTRING) {
                    size_t klen = 0;
                    const char *ks = lua_tolstring(L, -2, &klen);
                    keyStr = [[NSString alloc] initWithBytes:ks length:klen encoding:NSUTF8StringEncoding];
                } else if (lua_type(L, -2) == LUA_TNUMBER) {
                    if (lua_isinteger(L, -2))
                        keyStr = [NSString stringWithFormat:@"%lld", (long long)lua_tointeger(L, -2)];
                    else
                        keyStr = [NSString stringWithFormat:@"%g", lua_tonumber(L, -2)];
                }
                if (keyStr) {
                    dict[keyStr] = lua_to_objc(L, -1, depth + 1);
                }
                lua_pop(L, 1);
            }
            return dict;
        }
        default:
            return [NSNull null];
    }
}

static int l_json_decode(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:s length:len];
        NSError *err = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data
                                                 options:NSJSONReadingFragmentsAllowed
                                                   error:&err];
        if (err || !obj) {
            return luaL_error(L, "json.decode failed: %s",
                              err ? err.localizedDescription.UTF8String : "invalid JSON");
        }
        push_objc_to_lua(L, obj);
        return 1;
    }
}

static int l_json_encode(lua_State *L) {
    luaL_checkany(L, 1);
    @autoreleasepool {
        id obj = lua_to_objc(L, 1, 0);
        NSError *err = nil;
        NSData *data = nil;
        if ([NSJSONSerialization isValidJSONObject:obj]) {
            data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
        } else {
            // Fragment (string, number, bool, null)
            data = [NSJSONSerialization dataWithJSONObject:@[obj] options:0 error:&err];
            if (data && data.length >= 2) {
                data = [data subdataWithRange:NSMakeRange(1, data.length - 2)];
            }
        }
        if (err || !data) {
            return luaL_error(L, "json.encode failed: %s",
                              err ? err.localizedDescription.UTF8String : "encoding error");
        }
        lua_pushlstring(L, (const char *)data.bytes, data.length);
        return 1;
    }
}

int luaopen_tapcore_json(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, l_json_decode);
    lua_setfield(L, -2, "decode");
    lua_pushcfunction(L, l_json_encode);
    lua_setfield(L, -2, "encode");
    lua_pushlightuserdata(L, JSON_NULL_PTR);
    lua_setfield(L, -2, "null");
    return 1;
}
