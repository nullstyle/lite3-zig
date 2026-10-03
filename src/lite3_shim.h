/**
 * lite3_shim.h - C shim between the Zig wrapper and lite3.
 *
 * The Zig side reads documents itself (see src/lite3.zig); this shim only
 * covers what needs lite3's C code: inserting entries (B-tree insertion and
 * node splits) and JSON decoding (yyjson).
 *
 * Error convention: every function returning `int` returns a value >= 0 on
 * success and `-LITE3ZIG_E_*` on failure. The status is derived inside C, so
 * the Zig side never reads errno.
 */
#ifndef LITE3_SHIM_H
#define LITE3_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Status codes (negated on return) ---- */
enum {
    LITE3ZIG_OK = 0,
    LITE3ZIG_E_NOT_FOUND = 1,       /* ENOENT */
    LITE3ZIG_E_INVALID = 2,         /* EINVAL: rejected by lite3 (bad offset, index, type, corrupt tag) */
    LITE3ZIG_E_NO_SPACE = 3,        /* ENOBUFS / EMSGSIZE: buffer too small */
    LITE3ZIG_E_CORRUPT = 4,         /* EBADMSG / EFAULT: malformed document */
    LITE3ZIG_E_NO_MEMORY = 5,       /* ENOMEM */
    LITE3ZIG_E_KEY_COLLISION = 6,   /* ENOSPC: every hash probe slot holds another key */
    LITE3ZIG_E_JSON_SYNTAX = 7,     /* JSON input could not be parsed */
    LITE3ZIG_E_JSON_NESTING = 8,    /* JSON nested deeper than lite3 accepts */
    LITE3ZIG_E_JSON_KEY = 9,        /* JSON object key contains a NUL character */
    LITE3ZIG_E_JSON_ROOT = 10,      /* JSON root is not an object or array */
    LITE3ZIG_E_UNKNOWN = 11,        /* any other errno */
};

/* ---- Writing ---- */

/* Initialize an empty object (type 6) or array (type 7) at offset 0. */
int shim_init(unsigned char *buf, size_t *out_buflen, size_t bufsz, uint8_t type);

/* Insert or overwrite the entry for `key` (object; NUL-terminated, `key_size`
   includes the NUL) or for index `hash` (array; key == NULL, key_size == 0) in
   the container at `ofs`, making room for a scalar value whose payload is
   `payload_len` bytes. Writes the value's type byte and returns the offset of
   the payload in *out_payload_ofs; the caller writes the payload. */
int shim_insert(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz,
                const char *key, uint32_t hash, uint32_t key_size,
                uint8_t type, size_t payload_len, uint32_t *out_payload_ofs);

/* Like shim_insert, for a new empty object (type 6) or array (type 7).
   Returns the new container's offset in *out_ofs. */
int shim_insert_container(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz,
                          const char *key, uint32_t hash, uint32_t key_size,
                          uint8_t type, uint32_t *out_ofs);

/* ---- JSON decoding ---- */

/* Allocator used for yyjson's parse tree. `free` and `realloc` receive the
   size of the existing block. */
typedef struct {
    void *(*malloc)(void *ctx, size_t size);
    void *(*realloc)(void *ctx, void *ptr, size_t old_size, size_t size);
    void (*free)(void *ctx, void *ptr);
    void *ctx;
} shim_alc;

/* Where JSON parsing failed; filled when shim_json_parse returns
   -LITE3ZIG_E_JSON_SYNTAX. `message` is a static string owned by yyjson. */
typedef struct {
    uint32_t code;
    size_t position;
    const char *message;
} shim_json_diag;

/* Parse `json` and check it can be converted (object or array root, nesting
   within lite3's limit, no NUL in keys). On success *out_doc must later be
   released with shim_json_free. */
int shim_json_parse(const char *json, size_t json_len, const shim_alc *alc,
                    shim_json_diag *diag, void **out_doc);

/* Convert a parsed document into a lite3 document in `buf`. May be called
   again with a larger buffer after -LITE3ZIG_E_NO_SPACE. */
int shim_json_convert(void *doc, unsigned char *buf, size_t *out_buflen, size_t bufsz);

void shim_json_free(void *doc);

#ifdef __cplusplus
}
#endif

#endif /* LITE3_SHIM_H */
