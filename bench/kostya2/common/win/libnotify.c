/* common/libnotify of kostya/benchmarks over Winsock, for building its C and
   C++ tests on Windows (bench/kostya2/compare.py). */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <process.h>
#include <stdio.h>
#include <string.h>

#include "libnotify.h"

#pragma comment(lib, "ws2_32.lib")

static const size_t MAX_LEN = 48;

void notify(const char *msg) {
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    return;
  }
  SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (sock != INVALID_SOCKET) {
    struct sockaddr_in serv_addr;
    memset(&serv_addr, 0, sizeof serv_addr);
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(9001);
    inet_pton(AF_INET, "127.0.0.1", &serv_addr.sin_addr);
    if (!connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr))) {
      send(sock, msg, (int)strnlen(msg, MAX_LEN), 0);
    }
    closesocket(sock);
  }
  WSACleanup();
}

void notify_with_pid(const char *msg) {
  char text[MAX_LEN];
  if (snprintf(text, sizeof(text), "%s\t%d", msg, _getpid()) > 0) {
    notify(text);
  }
}
