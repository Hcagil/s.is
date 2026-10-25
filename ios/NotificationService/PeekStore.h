#ifndef SIS_PEEK_STORE_H
#define SIS_PEEK_STORE_H

/* What the notification extension reads from the app's encrypted store. Strings are heap copies; free them all with sis_peek_free. */
typedef struct {
  char *owner_id;       /* meta 'owner_id', or NULL */
  char *peer_user_id;   /* json_extract(conversations.json, '$.other.id'), or NULL */
  char *peer_name;      /* json_extract(conversations.json, '$.other.name'), or NULL */
  char *stored_body;    /* messages.body of (id, conversation_id) when not deleted, or NULL */
  char *account;        /* meta 'olm_account' (account pickle), or NULL */
  char *key_elsewhere;  /* "1" when a stored session with sender_key belongs to a peer other than sender_id, else NULL */
  int session_count;    /* sessions of peer_user_id, newest last_used_at first, at most 16 */
  char **session_ids;
  char **session_peer_ids;
  char **session_identity_keys;
  char **session_pickles;
  char *stored_sender;  /* messages.sender_id of that stored_body row, or NULL */
} SisPeekRows;

/* 0 ok; 1 not readable (missing file, not a database, wrong key, no cipher build); 2 still busy after about 1 second; 3 any other error. Opens read-only and never writes. Sessions are read for peer_user_id, or for sender_id when the chat has no known peer; sender_key and sender_id may be NULL. */
int sis_peek_read(const char *path, const char *key_hex, const char *conversation_id, const char *message_id, const char *sender_key, const char *sender_id, SisPeekRows *out);

/* Saves one opened message into push_inbox of the store, in one short transaction on a read-write connection that is closed before this returns. 0 saved; 1 store older than schema 5 (nothing written); 2 still busy after about 500 ms; 3 skipped (the real message row exists, or the chat is not in the store); 4 any other error or not readable. Never creates a file or table. */
int sis_peek_save(const char *path, const char *key_hex, const char *conversation_id, const char *message_id, const char *peer_user_id, const char *body, const char *sealed, long long received_at_micros);

/* Overwrites every string with zeros, frees all, zeroes the struct. Safe on a zeroed struct. */
void sis_peek_free(SisPeekRows *rows);

#endif /* SIS_PEEK_STORE_H */
