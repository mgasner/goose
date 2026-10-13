/* For the embed/ hosts: runs fn on a thread of the host's own, which the
   Goose library knows nothing about, and waits for it. */
#ifdef _WIN32
#include <windows.h>
static void (*host_thread_fn)(void);
static DWORD WINAPI host_thread_entry(LPVOID p) {
    (void)p;
    host_thread_fn();
    return 0;
}
static void run_on_host_thread(void (*fn)(void)) {
    HANDLE h;
    host_thread_fn = fn;
    h = CreateThread(NULL, 0, host_thread_entry, NULL, 0, NULL);
    WaitForSingleObject(h, INFINITE);
    CloseHandle(h);
}
#else
#include <pthread.h>
static void (*host_thread_fn)(void);
static void *host_thread_entry(void *p) {
    (void)p;
    host_thread_fn();
    return 0;
}
static void run_on_host_thread(void (*fn)(void)) {
    pthread_t t;
    host_thread_fn = fn;
    pthread_create(&t, 0, host_thread_entry, 0);
    pthread_join(t, 0);
}
#endif
