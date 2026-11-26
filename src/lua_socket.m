#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/in.h>
#import <poll.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "tapcore.h"

#define TAPCORE_SOCK_MT "TapCoreSocket"

typedef struct {
    int fd;
    double timeout; // < 0: blocking, 0: non-blocking, > 0: seconds
    int is_server;
} TapCoreSock;

static TapCoreSock *check_sock(lua_State *L, int idx) {
    return (TapCoreSock *)luaL_checkudata(L, idx, TAPCORE_SOCK_MT);
}

// Interruptible poll: wakes every <= 100ms to check tapcore_script_should_stop()
// Returns >0 ready, 0 timeout, -1 error, -2 stopped
static int wait_fd(int fd, short events, double timeout) {
    struct timeval startTv;
    gettimeofday(&startTv, NULL);
    double startSec = (double)startTv.tv_sec + (double)startTv.tv_usec / 1e6;

    for (;;) {
        if (tapcore_script_should_stop()) return -2;

        int sliceMs = 100;
        if (timeout == 0) {
            sliceMs = 0;
        } else if (timeout > 0) {
            struct timeval tv;
            gettimeofday(&tv, NULL);
            double elapsed = ((double)tv.tv_sec + (double)tv.tv_usec / 1e6) - startSec;
            double rem = timeout - elapsed;
            if (rem <= 0) return 0;
            int remMs = (int)(rem * 1000.0);
            if (remMs < sliceMs) sliceMs = remMs;
            if (sliceMs < 1) sliceMs = 1;
        }

        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = events;
        pfd.revents = 0;
        int r = poll(&pfd, 1, sliceMs);
        if (r > 0) return r;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (timeout == 0) return 0;
    }
}

static int l_socket_gettime(lua_State *L) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    lua_pushnumber(L, (double)tv.tv_sec + (double)tv.tv_usec / 1e6);
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

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (!host || strcmp(host, "*") == 0 || strcmp(host, "0.0.0.0") == 0) {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int e = errno;
        close(fd);
        lua_pushnil(L);
        lua_pushstring(L, strerror(e));
        return 2;
    }

    if (listen(fd, 64) != 0) {
        int e = errno;
        close(fd);
        lua_pushnil(L);
        lua_pushstring(L, strerror(e));
        return 2;
    }

    TapCoreSock *s = (TapCoreSock *)lua_newuserdata(L, sizeof(TapCoreSock));
    s->fd = fd;
    s->timeout = -1.0;
    s->is_server = 1;
    luaL_getmetatable(L, TAPCORE_SOCK_MT);
    lua_setmetatable(L, -2);
    return 1;
}

static int l_sock_settimeout(lua_State *L) {
    TapCoreSock *s = check_sock(L, 1);
    if (lua_isnoneornil(L, 2)) {
        s->timeout = -1.0;
    } else {
        s->timeout = luaL_checknumber(L, 2);
    }
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
        if (r == 0) {
            lua_pushnil(L);
            lua_pushliteral(L, "timeout");
            return 2;
        }
        if (r < 0) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            return 2;
        }
    }

    int cfd = accept(s->fd, NULL, NULL);
    if (cfd < 0) {
        lua_pushnil(L);
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            lua_pushliteral(L, "timeout");
        } else {
            lua_pushstring(L, strerror(errno));
        }
        return 2;
    }

    int opt = 1;
    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
    int flags = fcntl(cfd, F_GETFL, 0);
    if (flags >= 0) fcntl(cfd, F_SETFL, flags | O_NONBLOCK);

    TapCoreSock *cs = (TapCoreSock *)lua_newuserdata(L, sizeof(TapCoreSock));
    cs->fd = cfd;
    cs->timeout = -1.0;
    cs->is_server = 0;
    luaL_getmetatable(L, TAPCORE_SOCK_MT);
    lua_setmetatable(L, -2);
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

    struct timeval startTv;
    gettimeofday(&startTv, NULL);
    double startSec = (double)startTv.tv_sec + (double)startTv.tv_usec / 1e6;

    if (lua_type(L, 2) == LUA_TNUMBER) {
        lua_Integer need = lua_tointeger(L, 2);
        if (need <= 0) {
            lua_pushliteral(L, "");
            return 1;
        }
        char *buf = (char *)malloc((size_t)need);
        if (!buf) return luaL_error(L, "out of memory");
        size_t got = 0;
        while (got < (size_t)need) {
            double rem = -1.0;
            if (s->timeout >= 0) {
                struct timeval tv;
                gettimeofday(&tv, NULL);
                double now = (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
                rem = s->timeout - (now - startSec);
                if (rem <= 0) {
                    lua_pushnil(L);
                    lua_pushliteral(L, "timeout");
                    lua_pushlstring(L, buf, got);
                    free(buf);
                    return 3;
                }
            }
            int pr = wait_fd(s->fd, POLLIN, rem);
            if (pr == -2) { free(buf); return luaL_error(L, "__TAPCORE_STOPPED__"); }
            if (pr == 0) {
                lua_pushnil(L);
                lua_pushliteral(L, "timeout");
                lua_pushlstring(L, buf, got);
                free(buf);
                return 3;
            }
            if (pr < 0) {
                lua_pushnil(L);
                lua_pushstring(L, strerror(errno));
                lua_pushlstring(L, buf, got);
                free(buf);
                return 3;
            }
            ssize_t r = recv(s->fd, buf + got, (size_t)need - got, 0);
            if (r > 0) {
                got += (size_t)r;
            } else if (r == 0) {
                lua_pushnil(L);
                lua_pushliteral(L, "closed");
                lua_pushlstring(L, buf, got);
                free(buf);
                return 3;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                lua_pushnil(L);
                lua_pushstring(L, strerror(errno));
                lua_pushlstring(L, buf, got);
                free(buf);
                return 3;
            }
        }
        lua_pushlstring(L, buf, got);
        free(buf);
        return 1;
    }

    luaL_Buffer b;
    luaL_buffinit(L, &b);
    for (;;) {
        double rem = -1.0;
        if (s->timeout >= 0) {
            struct timeval tv;
            gettimeofday(&tv, NULL);
            double now = (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
            rem = s->timeout - (now - startSec);
            if (rem <= 0) {
                lua_pushnil(L);
                lua_pushliteral(L, "timeout");
                luaL_pushresult(&b);
                return 3;
            }
        }
        int pr = wait_fd(s->fd, POLLIN, rem);
        if (pr == -2) return luaL_error(L, "__TAPCORE_STOPPED__");
        if (pr == 0) {
            lua_pushnil(L);
            lua_pushliteral(L, "timeout");
            luaL_pushresult(&b);
            return 3;
        }
        if (pr < 0) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            luaL_pushresult(&b);
            return 3;
        }
        char ch = 0;
        ssize_t r = recv(s->fd, &ch, 1, 0);
        if (r == 1) {
            if (ch == '\n') {
                luaL_pushresult(&b);
                return 1;
            }
            if (ch != '\r') {
                luaL_addchar(&b, ch);
            }
        } else if (r == 0) {
            lua_pushnil(L);
            lua_pushliteral(L, "closed");
            luaL_pushresult(&b);
            return 3;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            luaL_pushresult(&b);
            return 3;
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

    struct timeval startTv;
    gettimeofday(&startTv, NULL);
    double startSec = (double)startTv.tv_sec + (double)startTv.tv_usec / 1e6;

    size_t offset = (size_t)(i - 1);
    size_t end = (size_t)j;
    while (offset < end) {
        double rem = -1.0;
        if (s->timeout >= 0) {
            struct timeval tv;
            gettimeofday(&tv, NULL);
            double now = (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
            rem = s->timeout - (now - startSec);
            if (rem <= 0) {
                lua_pushnil(L);
                lua_pushliteral(L, "timeout");
                lua_pushinteger(L, (lua_Integer)offset);
                return 3;
            }
        }
        int pr = wait_fd(s->fd, POLLOUT, rem);
        if (pr == -2) return luaL_error(L, "__TAPCORE_STOPPED__");
        if (pr == 0) {
            lua_pushnil(L);
            lua_pushliteral(L, "timeout");
            lua_pushinteger(L, (lua_Integer)offset);
            return 3;
        }
        if (pr < 0) {
            lua_pushnil(L);
            lua_pushstring(L, strerror(errno));
            lua_pushinteger(L, (lua_Integer)offset);
            return 3;
        }
        ssize_t w = send(s->fd, data + offset, end - offset, 0);
        if (w > 0) {
            offset += (size_t)w;
        } else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
            continue;
        } else {
            lua_pushnil(L);
            lua_pushstring(L, (w == 0) ? "closed" : strerror(errno));
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
