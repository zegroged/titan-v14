/**
 * @file tcp_session.h
 * @brief TCP Session Manager — Modem TCP/IP Stack
 *
 * ★ P1 #11: TLS Zorunlu — plaintext TCP bağlantısı REDDEDİLİR.
 *           AT+QSSLCFG ile sertifika pinning.
 */
#ifndef CALLWHITE_TCP_SESSION_H
#define CALLWHITE_TCP_SESSION_H

#include "config.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*============================================================================
 * Connection State
 *============================================================================*/
typedef enum {
  TCP_DISCONNECTED,
  TCP_CONNECTING,
  TCP_CONNECTED,
  TCP_SSL_HANDSHAKE, /* ★ P1 #11: TLS handshake in progress */
  TCP_ERROR,
} tcp_state_t;

/*============================================================================
 * ★ P1 #11: TLS / SSL Configuration
 *============================================================================*/

/* SSL context ID (EC25 supports 0-5) */
#define SSL_CTX_ID 0

/* SSL version: TLS 1.2 only (no TLS 1.0/1.1 fallback) */
#define SSL_VERSION 4 /* 4 = TLS 1.2 */

/* Cipher suite: AES-256-GCM with SHA-384 (strongest available) */
#define SSL_CIPHER_SUITE "0xC030" /* TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 */

/* Server certificate fingerprint for pinning (SHA-256, hex string)
 * TODO: Set actual server cert fingerprint during deployment */
#define SSL_SERVER_FINGERPRINT                                                 \
  "0000000000000000000000000000000000000000000000000000000000000000"

/* SSL authentication mode */
#define SSL_AUTH_MODE 2 /* 2 = Server and client auth (mutual TLS) */

/*============================================================================
 * AT Command Templates for TLS Setup
 *============================================================================*/

/*
 * SSL Configuration sequence (sent during tcp_session_init):
 *
 *   AT+QSSLCFG="sslversion",0,4        -> TLS 1.2
 *   AT+QSSLCFG="ciphersuite",0,0xC030  -> AES-256-GCM
 *   AT+QSSLCFG="seclevel",0,2          -> Mutual auth
 *   AT+QSSLCFG="cacert",0,"cacert.pem" -> CA certificate
 *   AT+QSSLCFG="clientcert",0,"cc.pem" -> Client certificate
 *   AT+QSSLCFG="clientkey",0,"ck.pem"  -> Client private key
 *
 * Connection:
 *   AT+QSSLOPEN=0,0,0,"server",port,0  -> SSL socket open
 *
 * Plaintext TCP (AT+QIOPEN) is NEVER used when TLS is mandatory.
 */

/*============================================================================
 * API
 *============================================================================*/

void tcp_session_init(void);
tcp_state_t tcp_get_state(void);

/**
 * @brief Connect to server with mandatory TLS.
 *
 * When SECURITY_TLS_MANDATORY is enabled:
 *   - Uses AT+QSSLOPEN instead of AT+QIOPEN
 *   - Verifies server certificate
 *   - Plaintext fallback is IMPOSSIBLE
 *
 * @param host  Server hostname or IP
 * @param port  Server port (typically 4433 for TLS)
 * @return true if connection initiated
 */
bool tcp_connect(const char *host, uint16_t port);

/**
 * @brief Connect over plaintext TCP (DISABLED in production).
 *
 * This function will FAIL with return false when
 * SECURITY_TLS_MANDATORY is set to 1.
 */
static inline bool tcp_connect_plaintext(const char *host, uint16_t port) {
#if SECURITY_TLS_MANDATORY
  /* ★ P1 #11: Plaintext TCP REJECTED — TLS mandatory */
  (void)host;
  (void)port;
  return false;
#else
  return tcp_connect(host, port);
#endif
}

bool tcp_send(const uint8_t *data, size_t len);
size_t tcp_recv(uint8_t *buf, size_t max_len);
void tcp_disconnect(void);

#endif /* CALLWHITE_TCP_SESSION_H */
