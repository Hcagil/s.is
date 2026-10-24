#include "PeekStore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "sqlite3.h"

static void wipe_free(char *s) {
  if (s == NULL) return;
  size_t len = strlen(s);
  volatile unsigned char *p = (volatile unsigned char *)s;
  for (size_t i = 0; i < len; i++) p[i] = 0;
  free(s);
}

void sis_peek_free(SisPeekRows *rows) {
  if (rows == NULL) return;
  for (int i = 0; i < rows->session_count; i++) {
    if (rows->session_ids) wipe_free(rows->session_ids[i]);
    if (rows->session_peer_ids) wipe_free(rows->session_peer_ids[i]);
    if (rows->session_identity_keys) wipe_free(rows->session_identity_keys[i]);
    if (rows->session_pickles) wipe_free(rows->session_pickles[i]);
  }
  free(rows->session_ids);
  free(rows->session_peer_ids);
  free(rows->session_identity_keys);
  free(rows->session_pickles);
  wipe_free(rows->owner_id);
  wipe_free(rows->peer_user_id);
  wipe_free(rows->peer_name);
  wipe_free(rows->stored_body);
  wipe_free(rows->account);
  wipe_free(rows->key_elsewhere);
  memset(rows, 0, sizeof *rows);
}

/* One text column of the first row of sql, bound to a (and b); *out stays NULL when there is no row. */
static int query_text(sqlite3 *db, const char *sql, const char *a, const char *b, char **out) {
  sqlite3_stmt *stmt;
  *out = NULL;
  int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
  if (rc != SQLITE_OK) return rc;
  rc = sqlite3_bind_text(stmt, 1, a, -1, SQLITE_TRANSIENT);
  if (rc == SQLITE_OK && b != NULL) rc = sqlite3_bind_text(stmt, 2, b, -1, SQLITE_TRANSIENT);
  if (rc != SQLITE_OK) {
    sqlite3_finalize(stmt);
    return rc;
  }
  rc = sqlite3_step(stmt);
  if (rc == SQLITE_ROW) {
    const unsigned char *text = sqlite3_column_text(stmt, 0);
    if (text != NULL) {
      *out = strdup((const char *)text);
      if (*out == NULL) rc = SQLITE_NOMEM;
    }
  }
  sqlite3_finalize(stmt);
  return (rc == SQLITE_ROW || rc == SQLITE_DONE) ? SQLITE_OK : rc;
}

static char *dup_col(sqlite3_stmt *s, int i) {
  const unsigned char *text = sqlite3_column_text(s, i);
  return text == NULL ? NULL : strdup((const char *)text);
}

static int read_sessions(sqlite3 *db, const char *peer, SisPeekRows *out) {
  sqlite3_stmt *stmt;
  int rc = sqlite3_prepare_v2(db, "SELECT session_id, peer_user_id, peer_identity_key, pickle FROM olm_sessions WHERE peer_user_id = ?1 ORDER BY last_used_at DESC LIMIT 16", -1, &stmt, NULL);
  if (rc != SQLITE_OK) return rc;
  rc = sqlite3_bind_text(stmt, 1, peer, -1, SQLITE_TRANSIENT);
  if (rc != SQLITE_OK) {
    sqlite3_finalize(stmt);
    return rc;
  }
  out->session_ids = calloc(16, sizeof(char *));
  out->session_peer_ids = calloc(16, sizeof(char *));
  out->session_identity_keys = calloc(16, sizeof(char *));
  out->session_pickles = calloc(16, sizeof(char *));
  if (!out->session_ids || !out->session_peer_ids || !out->session_identity_keys || !out->session_pickles) {
    sqlite3_finalize(stmt);
    return SQLITE_NOMEM;  /* the caller's sis_peek_free frees what was made */
  }
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    char *id = dup_col(stmt, 0), *pid = dup_col(stmt, 1), *key = dup_col(stmt, 2), *pickle = dup_col(stmt, 3);
    if (!id || !pid || !key || !pickle) {
      wipe_free(id);
      wipe_free(pid);
      wipe_free(key);
      wipe_free(pickle);
      sqlite3_finalize(stmt);
      return SQLITE_NOMEM;
    }
    int n = out->session_count;
    out->session_ids[n] = id;
    out->session_peer_ids[n] = pid;
    out->session_identity_keys[n] = key;
    out->session_pickles[n] = pickle;
    out->session_count = n + 1;
  }
  sqlite3_finalize(stmt);
  return rc == SQLITE_DONE ? SQLITE_OK : rc;
}

/* Opens read-only and unlocks with the raw key; the pragmas keep memory small and forbid writes. */
static int open_keyed(const char *path, const char *key_hex, sqlite3 **db) {
  char pragma[96];
  *db = NULL;
  int rc = sqlite3_open_v2(path, db, SQLITE_OPEN_READONLY, NULL);
  if (rc == SQLITE_OK) {
    snprintf(pragma, sizeof pragma, "PRAGMA key = \"x'%s'\";", key_hex);
    rc = sqlite3_exec(*db, pragma, 0, 0, 0);
    { volatile char *w = pragma; for (size_t i = 0; i < sizeof pragma; i++) w[i] = 0; }
  }
  if (rc == SQLITE_OK) {
    rc = sqlite3_exec(*db, "PRAGMA busy_timeout = 1000; PRAGMA query_only = 1; PRAGMA cache_size = -256; PRAGMA mmap_size = 0;", 0, 0, 0);
  }
  if (rc != SQLITE_OK && *db != NULL) {
    sqlite3_close(*db);
    *db = NULL;
  }
  return rc;
}

/* A plain SQLite (no cipher build) answers PRAGMA cipher with no row: refuse it, it would ignore the key. */
static int cipher_present(sqlite3 *db) {
  sqlite3_stmt *stmt;
  int ok = 0;
  if (sqlite3_prepare_v2(db, "PRAGMA cipher;", -1, &stmt, 0) != SQLITE_OK) return 0;
  if (sqlite3_step(stmt) == SQLITE_ROW) {
    const unsigned char *name = sqlite3_column_text(stmt, 0);
    ok = name != NULL && name[0] != '\0';
  }
  sqlite3_finalize(stmt);
  return ok;
}

static int read_all(sqlite3 *db, const char *conversation_id, const char *message_id, const char *sender_key, const char *sender_id, SisPeekRows *out) {
  int rc = sqlite3_exec(db, "BEGIN;", 0, 0, 0);
  if (rc != SQLITE_OK) return rc;
  rc = query_text(db, "SELECT value FROM meta WHERE key = ?1", "owner_id", NULL, &out->owner_id);
  if (rc == SQLITE_OK) rc = query_text(db, "SELECT value FROM meta WHERE key = ?1", "olm_account", NULL, &out->account);
  if (rc == SQLITE_OK) rc = query_text(db, "SELECT json_extract(json, '$.other.id') FROM conversations WHERE id = ?1", conversation_id, NULL, &out->peer_user_id);
  if (rc == SQLITE_OK) rc = query_text(db, "SELECT json_extract(json, '$.other.name') FROM conversations WHERE id = ?1", conversation_id, NULL, &out->peer_name);
  if (rc == SQLITE_OK) rc = query_text(db, "SELECT body FROM messages WHERE id = ?1 AND conversation_id = ?2 AND deleted IS NULL", message_id, conversation_id, &out->stored_body);
  const char *peer = out->peer_user_id != NULL ? out->peer_user_id : sender_id;
  if (rc == SQLITE_OK && peer != NULL) rc = read_sessions(db, peer, out);
  if (rc == SQLITE_OK && sender_key != NULL && sender_id != NULL) rc = query_text(db, "SELECT '1' WHERE EXISTS (SELECT 1 FROM olm_sessions WHERE peer_identity_key = ?1 AND peer_user_id <> ?2)", sender_key, sender_id, &out->key_elsewhere);
  sqlite3_exec(db, "ROLLBACK;", 0, 0, 0);  /* read only: nothing to commit */
  return rc;
}

static int valid_key_hex(const char *s) {
  if (strlen(s) != 64) return 0;
  for (int i = 0; i < 64; i++) {
    if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
  }
  return 1;
}

int sis_peek_read(const char *path, const char *key_hex, const char *conversation_id, const char *message_id, const char *sender_key, const char *sender_id, SisPeekRows *out) {
  struct timespec start, now;
  memset(out, 0, sizeof *out);
  if (!path || !key_hex || !conversation_id || !message_id || !valid_key_hex(key_hex)) return 1;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    sqlite3 *db = NULL;
    int rc = open_keyed(path, key_hex, &db);
    if (rc == SQLITE_OK) {
      if (!cipher_present(db)) {
        sqlite3_close(db);
        return 1;
      }
      rc = read_all(db, conversation_id, message_id, sender_key, sender_id, out);
      sqlite3_close(db);
    }
    if (rc == SQLITE_OK) return 0;
    sis_peek_free(out);
    if (rc == SQLITE_NOTADB || rc == SQLITE_CORRUPT || rc == SQLITE_CANTOPEN) return 1;
    if (rc != SQLITE_BUSY && rc != SQLITE_LOCKED) return 3;
    /* The busy timeout alone does not cover every lock: retry the whole read for about 1 s. */
    clock_gettime(CLOCK_MONOTONIC, &now);
    if ((now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000 > 1000) return 2;
    struct timespec nap = {0, 25000000};
    nanosleep(&nap, NULL);
  }
}
