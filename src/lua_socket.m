#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "tapcore.h"

// Minimal TCP socket module for Lua (socket.bind / accept / receive / send / settimeout / close).
// Reads are buffered (one recv per chunk instead of one per byte) and every wait is sliced so a
// script Stop interrupts it within ~100 ms.

#define TAPCORE_SOCK_MT  "TapCoreSocket"
#define TAPCORE_SOCK_BUF 8192

typedef struct {
    int fd;
    double timeout;  // < 0: blocking, 0: non-blocking, > 0: seconds
    int is_server;
    size_t rpos, rlen;               // unread bytes are rbuf[rpos .. rlen)
    char rbuf[TAPCORE_SOCK_BUF];
} TapCoreSock;

static TapCoreSock *check_sock(lua_State *L, int idx) {
    return (TapCoreSock *)luaL_checkudata(L, idx, TAPCORE_SOCK_MT);
}

static double now_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

// Interruptible poll: wakes every <= 100ms to check tapcore_script_should_stop()
// Returns >0 ready, 0 timeout, -1 error, -2 stopped
static int wait_fd(int fd, short events, double timeout) {
    double start = now_sec();
    for (;;) {
        if (tapcore_script_should_stop()) return -2;

        int sliceMs = 100;
        if (timeout == 0) {
            sliceMs = 0;
        } else if (timeout > 0) {
            double rem = timeout - (now_sec() - start);
            if (rem <= 0) return 0;
            int remMs = (int)(rem * 1000.0);
            if (remMs < sliceMs) sliceMs = remMs;
            if (sliceMs < 1) sliceMs = 1;
        }

        struct pollfd pfd = { .fd = fd, .events = events, .revents = 0 };
        int r = poll(&pfd, 1, sliceMs);
        if (r > 0) return r;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (timeout == 0) return 0;
    }
}

// Remaining time for an operation started at `start`; -1 = no limit. Returns 0 when expired.
static double remaining(const TapCoreSock *s, double start) {
    if (s->timeout < 0) return -1.0;
    double rem = s->timeout - (now_sec() - start);
    return rem > 0 ? rem : 0.0;
}

// Refill the read buffer. Returns 1 data, 0 closed, -1 error (errno), -2 stopped, -3 timeout.
static int fill_buffer(TapCoreSock *s, double start) {
    for (;;) {
        double rem = remaining(s, start);
        if (s->timeout > 0 && rem <= 0) return -3;
        int pr = wait_fd(s->fd, POLLIN, rem);
        if (pr == -2) return -2;
        if (pr == 0) return -3;
        if (pr < 0) return -1;
        ssize_t r = recv(s->fd, s->rbuf, sizeof(s->rbuf), 0);
        if (r > 0) {
            s->rpos = 0;
            s->rlen = (size_t)r;
            return 1;
        }
        if (r == 0) return 0;
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -1;
        if (s->timeout == 0) return -3;
    }
}

// Push LuaSocket-style failure: nil, err, partial (partial is already on the stack top).
static int push_fail_with_partial(lua_State *L, int code) {
    const char *msg = (code == 0) ? "closed" : (code == -3) ? "timeout" : strerror(errno);
    lua_pushnil(L);
    lua_insert(L, -2);
    lua_pushstring(L, msg);
    lua_insert(L, -2);
    return 3;
}

static void set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static TapCoreSock *push_sock(lua_State *L, int fd, int is_server) {
    TapCoreSock *s = (TapCoreSock *)lua_newuserdata(L, sizeof(TapCoreSock));
    s->fd = fd;
    s->timeout = -1.0;
    s->is_server = is_server;
    s->rpos = s->rlen = 0;
    luaL_getmetatable(L, TAPCORE_SOCK_MT);
    lua_setmetatable(L, -2);
    return s;
}

static int l_socket_gettime(lua_State *L) {
    lua_pushnumber(L, now_sec());
    return 1;
}

static int l_socket_bind(lua_State *L) {
    const char *host = luaL_optstring(L, 1, "0.0.0.0");
    int port = (int)luaL_checkinteger(L, 2);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
    set_nonblocking(fd);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (!host || strcmp(host, "*") == 0 || strcmp(host, "0.0.0.0") == 0 ||
        inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 64) != 0) {
        int e = errno;
        close(fd);
        lua_pushnil(L);
        lua_pushstring(L, strerror(e));
        return 2;
    }
    push_sock(L, fd, 1);
    return 1;
}

static int l_sock_settimeout(lua_State *L) {
    TapCoreSock *s = check_sock(L, 1);
    s->timeout = lua_isnoneornil(L, 2) ? -1.0 : luaL_checknumber(L, 2);
    lua_pushinteger(L, 1);
    return 1;
}

static int l_sock_accept(lua_State *L) {
    TapCoreSock *s = check_sock(L, 1);
    if (tapcore_script_should_stop()) return luaL_error(L, "__TAPCORE_STOPPED__");
    if (s->fd < 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "closed");
        return 2;
    }
    if (s->timeout != 0) {
        int r = wait_fd(s->fd, POLLIN, s->timeout);
        if (r == -2) return luaL_error(L, "__TAPCORE_STOPPED__");
        if (r <= 0) {
            lua_pushnil(L);
            if (r == 0) lua_pushliteral(L, "timeout"); else lua_pushstring(L, strerror(errno));
            return 2;
        }
    }
    int cfd = accept(s->fd, NULL, NULL);
    if (cfd < 0) {
        lua_pushnil(L);
        if (errno == EAGAIN || errno == EWOULDBLOCK) lua_pushliteral(L, "timeout");
        else lua_pushstring(L, strerror(errno));
        return 2;
    }
    int opt = 1;
    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));   // reply goes out immediately
    set_nonblocking(cfd);
    push_sock(L, cfd, 0);
    return 1;
}

static int l_sock_receive(lua_State *L) {
    TapCoreSock *s = check_sock(L, 1);
    if (tapcore_script_should_stop()) return luaL_error(L, "__TAPCORE_STOPPED__");
    if (s->fd < 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "closed");
        lua_pushliteral(L, "");
        return 3;
    }
    double start = now_sec();
    luaL_Buffer b;

    if (lua_type(L, 2) == LUA_TNUMBER) {         // receive(n): exactly n bytes
        lua_Integer need = lua_tointeger(L, 2);
        if (need <= 0) {
            lua_pushliteral(L, "");
            return 1;
        }
        size_t want = (size_t)need;
        luaL_buffinit(L, &b);
        while (want > 0) {
            if (s->rpos < s->rlen) {
                size_t take = s->rlen - s->rpos;
                if (take > want) take = want;
                luaL_addlstring(&b, s->rbuf + s->rpos, take);
                s->rpos += take;
                want -= take;
                continue;
            }
            int fr = fill_buffer(s, start);
            if (fr == -2) return luaL_error(L, "__TAPCORE_STOPPED__");
            if (fr != 1) {
                luaL_pushresult(&b);
                return push_fail_with_partial(L, fr);
            }
        }
        luaL_pushresult(&b);
        return 1;
    }

    luaL_buffinit(L, &b);                         // receive(): one line, without CR/LF
    for (;;) {
        while (s->rpos < s->rlen) {
            char *line = s->rbuf + s->rpos;
            size_t avail = s->rlen - s->rpos;
            char *nl = memchr(line, '\n', avail);
            size_t chunk = nl ? (size_t)(nl - line) : avail;
            for (size_t i = 0; i < chunk; i++) {
                if (line[i] != '\r') luaL_addchar(&b, line[i]);
            }
            s->rpos += chunk;
            if (nl) {
                s->rpos += 1;
                luaL_pushresult(&b);
                return 1;
            }
        }
        int fr = fill_buffer(s, start);
        if (fr == -2) return luaL_error(L, "__TAPCORE_STOPPED__");
        if (fr != 1) {
            luaL_pushresult(&b);
            return push_fail_with_partial(L, fr);
        }
    }
}

static int l_sock_send(lua_State *L) {
    TapCoreSock *s = check_sock(L, 1);
    size_t len = 0;
    const char *data = luaL_checklstring(L, 2, &len);
    lua_Integer i = luaL_optinteger(L, 3, 1);
    lua_Integer j = luaL_optinteger(L, 4, (lua_Integer)len);

    if (s->fd < 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "closed");
        lua_pushinteger(L, i - 1);
        return 3;
    }
    if (i < 1) i = 1;
    if (j > (lua_Integer)len) j = (lua_Integer)len;
    if (i > j) {
        lua_pushinteger(L, i - 1);
        return 1;
    }

    double start = now_sec();
    size_t offset = (size_t)(i - 1);
    size_t end = (size_t)j;
    while (offset < end) {
        ssize_t w = send(s->fd, data + offset, end - offset, 0);   // try first, wait only if full
        if (w > 0) {
            offset += (size_t)w;
            continue;
        }
        if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            lua_pushinteger(L, (lua_Integer)offset);
            return 3;
        }
        double rem = remaining(s, start);
        int pr = (s->timeout > 0 && rem <= 0) ? 0 : wait_fd(s->fd, POLLOUT, rem);
        if (pr == -2) return luaL_error(L, "__TAPCORE_STOPPED__");
        if (pr <= 0) {
            lua_pushnil(L);
            if (pr == 0) lua_pushliteral(L, "timeout"); else lua_pushstring(L, strerror(errno));
            lua_pushinteger(L, (lua_Integer)offset);
            return 3;
        }
    }
    lua_pushinteger(L, (lua_Integer)end);
    return 1;
}

static int l_sock_close(lua_State *L) {
    TapCoreSock *s = check_sock(L, 1);
    if (s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }
    s->rpos = s->rlen = 0;
    lua_pushinteger(L, 1);
    return 1;
}

static int l_sock_gc(lua_State *L) {
    TapCoreSock *s = (TapCoreSock *)luaL_testudata(L, 1, TAPCORE_SOCK_MT);
    if (s && s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }
    return 0;
}

int luaopen_tapcore_socket(lua_State *L) {
    luaL_newmetatable(L, TAPCORE_SOCK_MT);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    static const luaL_Reg sock_methods[] = {
        {"settimeout", l_sock_settimeout},
        {"accept",     l_sock_accept},
        {"receive",    l_sock_receive},
        {"send",       l_sock_send},
        {"close",      l_sock_close},
        {"__gc",       l_sock_gc},
        {NULL, NULL}
    };
    luaL_setfuncs(L, sock_methods, 0);
    lua_pop(L, 1);

    lua_newtable(L);
    lua_pushcfunction(L, l_socket_gettime);
    lua_setfield(L, -2, "gettime");
    lua_pushcfunction(L, l_socket_bind);
    lua_setfield(L, -2, "bind");
    return 1;
}
