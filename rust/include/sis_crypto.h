#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Olm round trip through the same wrapper Dart uses: returns 0 when "hi" encrypted by one account decrypts on another, else the number of the failing step (1..5).
 */
int32_t sis_olm_selftest(void);

/**
 * Return codes: 0 ok; 1 bad argument; 2 pickle or key rejected; 3 cannot decrypt; 4 envelope refused (not v1, or its id is not message_id); 5 output buffer too small; 6 internal error. On 0, out holds out_len bytes of UTF-8 text (not NUL terminated). key is the 32-byte pickle key. Strings are NUL-terminated UTF-8; ct_b64 is the standard base64 of the Olm message body. Nothing is ever saved; every secret buffer made inside is wiped before return.
 */

/** Session id inside a pre-key message (olm_type 0); written to out. */
int32_t sis_peek_prekey_session_id(const char *ct_b64, int32_t olm_type, uint8_t *out, size_t out_cap, size_t *out_len);

/** Decrypts with a copy of a stored session pickle (olm_type 0 or 1). */
int32_t sis_peek_session(const uint8_t *key, size_t key_len, const char *pickle, const char *message_id, const char *ct_b64, int32_t olm_type, uint8_t *out, size_t out_cap, size_t *out_len);

/** Pre-key message (olm_type 0) from a peer with no stored session: inbound session on a copy of the account pickle. */
int32_t sis_peek_inbound(const uint8_t *key, size_t key_len, const char *account_pickle, const char *identity_key, const char *message_id, const char *ct_b64, int32_t olm_type, uint8_t *out, size_t out_cap, size_t *out_len);
