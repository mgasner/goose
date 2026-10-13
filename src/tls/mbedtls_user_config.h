/* What the TLS layer changes of Mbed TLS's default configuration
   (third_party/mbedtls/include/mbedtls/mbedtls_config.h), which
   cmake/tls.cmake applies through MBEDTLS_USER_CONFIG_FILE. The defaults
   already give TLS 1.2 and 1.3, both client and server, X.509 and PEM, and
   the PSA crypto core that TLS 1.3 runs on. */

/* Threads. Every session and configuration is kept to one thread, but the
   PSA crypto core is global to the process, and a TLS 1.3 handshake goes
   through it: the configuration's own notes require the threading layer
   for any program where more than one thread does TLS. */
#define MBEDTLS_THREADING_C
#define MBEDTLS_THREADING_PTHREAD

/* Off: what HTTP over TCP never uses, and what a server should not offer. */
#undef MBEDTLS_SSL_RENEGOTIATION
#undef MBEDTLS_SSL_PROTO_DTLS
#undef MBEDTLS_SSL_DTLS_ANTI_REPLAY
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID_COMPAT
#undef MBEDTLS_SSL_COOKIE_C
#undef MBEDTLS_DEBUG_C
#undef MBEDTLS_SELF_TEST
