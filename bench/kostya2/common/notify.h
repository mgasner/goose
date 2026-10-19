/* The measurement protocol of kostya/benchmarks, for Goose programs, which
   reach it through `extern fn` and `--include notify.h`: a TCP message to
   localhost:9001 starts the measurement ("<name>\t<pid>"), another stops it.
   On POSIX this is the suite's own common/libnotify, linked as the C and C++
   tests link it; on Windows, where that library does not build, the same
   messages go through Winsock, so that bench/kostya2/compare.py can run the
   suite there. Either way a missing runner is not an error. */

#include <stdio.h>
#include <string.h>

#ifdef __clang__
#define GOOSE_NOTIFY_CC "clang"
#else
#define GOOSE_NOTIFY_CC "gcc"
#endif

#ifdef _WIN32

#include <winsock2.h>
#include <ws2tcpip.h>
#include <process.h>
#pragma comment(lib, "ws2_32.lib")

static void goose_notify_send(const char *msg) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return;
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock != INVALID_SOCKET) {
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(9001);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        if (connect(sock, (struct sockaddr *)&addr, sizeof addr) == 0)
            send(sock, msg, (int)strlen(msg), 0);
        closesocket(sock);
    }
    WSACleanup();
}

static int goose_notify_pid(void) { return _getpid(); }

#else

#include <unistd.h>
#include <libnotify.h>

static void goose_notify_send(const char *msg) { notify(msg); }

static int goose_notify_pid(void) { return (int)getpid(); }

#endif

/* "Goose/<C compiler><variant>\t<pid>": the name of the test, as the other
   languages' tests name theirs ("C/clang", "Rust (Serde Typed)"). */
void goose_notify_start(sl_u8 variant) {
    char msg[96];
    snprintf(msg, sizeof msg, "Goose/%s%.*s\t%d", GOOSE_NOTIFY_CC, (int)variant.len,
             (const char *)variant.data, goose_notify_pid());
    goose_notify_send(msg);
}

void goose_notify_stop(void) { goose_notify_send("stop"); }
