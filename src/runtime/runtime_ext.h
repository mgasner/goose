/* Goose runtime: extern-fn support, spliced in after the generated type
   declarations, since it is written against them: sl_u8 (a u8 slice: data,
   len) and gs_rref (a reference to a resizable: its header and its data
   stack). The runtime object has no generated types, and lays out the ones
   it uses here as codegen does (CodeGen::EmitCoreTypes, CT). An --include
   header follows this and may use what it defines. The generated program
   calls the OS primitives behind stdlib/os.goose (spec §7.10, defined in
   runtime_os.h) and the sockets behind stdlib/http.goose (runtime_net.h)
   directly from `extern "gs_os_..." fn` and `extern "gs_net_..." fn`
   declarations; no prototype is emitted for a function declared here. */

#ifdef GS_RUNTIME_OBJECT
#pragma pack(push, 1)
typedef struct { uint8_t *base; int64_t len; } gs_rhdr;
typedef struct { gs_rhdr *hdr; gs_stack *stk; } gs_rref;
typedef struct { uint8_t *data; int64_t len; } sl_u8;
#pragma pack(pop)
#endif

/* Appends n bytes to the u8[>..] a builder reference points at: the
   resizable's elements top its stack, so the bytes go at the stack top and
   the header's count grows. */
static void gs_bld_append(gs_rref b, const void *p, int64_t n) {
    if (n <= 0) return;
    memcpy(b.stk->top, p, (size_t)n);
    b.stk->top += n;
    b.hdr->len += n;
}

GS_API uint8_t gs_os_read_file(sl_u8 path, gs_rref out);
GS_API uint8_t gs_os_write_file(sl_u8 path, sl_u8 data);
GS_API uint8_t gs_os_write_file_atomic(sl_u8 path, sl_u8 data);
GS_API uint8_t gs_os_append_file(sl_u8 path, sl_u8 data);
GS_API uint8_t gs_os_file_exists(sl_u8 path);
GS_API uint8_t gs_os_remove_file(sl_u8 path);
GS_API uint8_t gs_os_rename_file(sl_u8 from, sl_u8 to);
GS_API uint8_t gs_os_make_dir(sl_u8 path);
GS_API uint8_t gs_os_is_dir(sl_u8 path);
GS_API uint8_t gs_os_remove_dir(sl_u8 path);
GS_API uint8_t gs_os_list_dir(sl_u8 path, gs_rref out);
GS_API void gs_os_write_stdout(sl_u8 s);
GS_API void gs_os_write_stderr(sl_u8 s);
GS_API void gs_os_flush_stdout(void);
GS_API uint8_t gs_os_read_line(gs_rref out);
GS_API void gs_os_read_stdin(gs_rref out);
GS_API int64_t gs_os_arg_count(void);
GS_API void gs_os_arg(int64_t i, gs_rref out);
GS_API uint8_t gs_os_getenv(sl_u8 name, gs_rref out);
GS_API int64_t gs_os_time_ns(void);
GS_API int64_t gs_os_clock_ns(void);
GS_API void gs_os_sleep_ms(int64_t ms);
GS_API uint64_t gs_os_random_u64(void);
GS_API int64_t gs_net_listen(sl_u8 host, int64_t port, int64_t backlog);
GS_API int64_t gs_net_port(int64_t fd);
GS_API int64_t gs_net_open(int64_t lfd, int64_t idle_ms);
GS_API int64_t gs_net_wait(int64_t id, gs_rref buf);
GS_API uint8_t gs_net_write(int64_t id, int64_t h, sl_u8 a, sl_u8 b);
GS_API void gs_net_done(int64_t id, int64_t h, sl_u8 rest, int64_t need, uint8_t close_);
GS_API int64_t gs_net_live(int64_t id);
GS_API void gs_net_close(int64_t id);
GS_API int64_t gs_net_connect(sl_u8 host, int64_t port, int64_t timeout_ms);
GS_API uint8_t gs_net_send(int64_t fd, sl_u8 data);
GS_API int64_t gs_net_recv(int64_t fd, gs_rref out, int64_t max);
GS_API void gs_net_close_fd(int64_t fd);
GS_API int64_t gs_net_date(sl_u8 out);
