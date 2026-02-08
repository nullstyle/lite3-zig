/**
 * lite3_shim.h - C shim for lite3 inline functions that Zig's cImport
 * cannot translate due to alignment casts and flexible array members.
 *
 * These functions wrap the static inline functions from lite3.h and
 * lite3_context_api.h, exposing them as regular extern C functions.
 */
#ifndef LITE3_SHIM_H
#define LITE3_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Buffer API: Object get ---- */
int shim_lite3_get_bool(const unsigned char *buf, size_t buflen, size_t ofs,
                        const char *key, bool *out);
int shim_lite3_get_i64(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, int64_t *out);
int shim_lite3_get_f64(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, double *out);
int shim_lite3_get_str(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, const char **out_ptr, uint32_t *out_len);
int shim_lite3_get_bytes(const unsigned char *buf, size_t buflen, size_t ofs,
                         const char *key, const unsigned char **out_ptr, uint32_t *out_len);
int shim_lite3_get_obj(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, size_t *out_ofs);
int shim_lite3_get_arr(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, size_t *out_ofs);
int shim_lite3_get_type(const unsigned char *buf, size_t buflen, size_t ofs,
                        const char *key);
int shim_lite3_exists(const unsigned char *buf, size_t buflen, size_t ofs,
                      const char *key);

/* ---- Buffer API: Object set ---- */
int shim_lite3_set_null(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                        size_t bufsz, const char *key);
int shim_lite3_set_bool(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                        size_t bufsz, const char *key, bool value);
int shim_lite3_set_i64(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, int64_t value);
int shim_lite3_set_f64(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, double value);
int shim_lite3_set_str(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, const char *str, size_t str_len);
int shim_lite3_set_bytes(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                         size_t bufsz, const char *key, const unsigned char *data, size_t data_len);
int shim_lite3_set_obj(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, size_t *out_ofs);
int shim_lite3_set_arr(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, size_t *out_ofs);

/* ---- Buffer API: Array append ---- */
int shim_lite3_arr_append_null(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz);
int shim_lite3_arr_append_bool(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, bool value);
int shim_lite3_arr_append_i64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, int64_t value);
int shim_lite3_arr_append_f64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, double value);
int shim_lite3_arr_append_str(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *str, size_t str_len);
int shim_lite3_arr_append_bytes(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const unsigned char *data, size_t data_len);
int shim_lite3_arr_append_obj(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, size_t *out_ofs);
int shim_lite3_arr_append_arr(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, size_t *out_ofs);

/* ---- Buffer API: Array get ---- */
int shim_lite3_arr_get_bool(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, bool *out);
int shim_lite3_arr_get_i64(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, int64_t *out);
int shim_lite3_arr_get_f64(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, double *out);
int shim_lite3_arr_get_str(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, const char **out_ptr, uint32_t *out_len);
int shim_lite3_arr_get_bytes(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, const unsigned char **out_ptr, uint32_t *out_len);
int shim_lite3_arr_get_obj(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, size_t *out_ofs);
int shim_lite3_arr_get_arr(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, size_t *out_ofs);
int shim_lite3_arr_get_type(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index);

/* ---- Buffer API: Utility ---- */
int shim_lite3_count(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t *out);

/* ---- Buffer API: Iterator ---- */
typedef struct {
    uint32_t _opaque[16];
} shim_lite3_iter;

int shim_lite3_iter_create(const unsigned char *buf, size_t buflen, size_t ofs, shim_lite3_iter *iter);
/* Returns 0 on success, 1 when done, < 0 on error.
   key_ptr/key_len are set for object iterators, key_ptr is NULL for arrays. */
int shim_lite3_iter_next(const unsigned char *buf, size_t buflen, shim_lite3_iter *iter,
                         const char **key_ptr, uint32_t *key_len, size_t *val_ofs);

/* ---- Buffer API: JSON ---- */
int shim_lite3_json_dec(unsigned char *buf, size_t *out_buflen, size_t bufsz,
                        const char *json_str, size_t json_len);
char *shim_lite3_json_enc(const unsigned char *buf, size_t buflen, size_t ofs, size_t *out_len);
char *shim_lite3_json_enc_pretty(const unsigned char *buf, size_t buflen, size_t ofs, size_t *out_len);
int64_t shim_lite3_json_enc_buf(const unsigned char *buf, size_t buflen, size_t ofs,
                                char *json_buf, size_t json_bufsz);

/* ---- Context API ---- */
typedef struct lite3_ctx lite3_ctx;

lite3_ctx *shim_lite3_ctx_create(void);
lite3_ctx *shim_lite3_ctx_create_with_size(size_t bufsz);
lite3_ctx *shim_lite3_ctx_create_from_buf(const unsigned char *buf, size_t buflen);
void shim_lite3_ctx_destroy(lite3_ctx *ctx);
unsigned char *shim_lite3_ctx_buf(lite3_ctx *ctx);
size_t shim_lite3_ctx_buflen(lite3_ctx *ctx);
size_t shim_lite3_ctx_bufsz(lite3_ctx *ctx);

int shim_lite3_ctx_init_obj(lite3_ctx *ctx);
int shim_lite3_ctx_init_arr(lite3_ctx *ctx);

int shim_lite3_ctx_set_null(lite3_ctx *ctx, size_t ofs, const char *key);
int shim_lite3_ctx_set_bool(lite3_ctx *ctx, size_t ofs, const char *key, bool value);
int shim_lite3_ctx_set_i64(lite3_ctx *ctx, size_t ofs, const char *key, int64_t value);
int shim_lite3_ctx_set_f64(lite3_ctx *ctx, size_t ofs, const char *key, double value);
int shim_lite3_ctx_set_str(lite3_ctx *ctx, size_t ofs, const char *key, const char *str, size_t str_len);
int shim_lite3_ctx_set_bytes(lite3_ctx *ctx, size_t ofs, const char *key, const unsigned char *data, size_t data_len);
int shim_lite3_ctx_set_obj(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs);
int shim_lite3_ctx_set_arr(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs);

int shim_lite3_ctx_get_type(lite3_ctx *ctx, size_t ofs, const char *key);
int shim_lite3_ctx_exists(lite3_ctx *ctx, size_t ofs, const char *key);
int shim_lite3_ctx_get_bool(lite3_ctx *ctx, size_t ofs, const char *key, bool *out);
int shim_lite3_ctx_get_i64(lite3_ctx *ctx, size_t ofs, const char *key, int64_t *out);
int shim_lite3_ctx_get_f64(lite3_ctx *ctx, size_t ofs, const char *key, double *out);
int shim_lite3_ctx_get_str(lite3_ctx *ctx, size_t ofs, const char *key, const char **out_ptr, uint32_t *out_len);
int shim_lite3_ctx_get_bytes(lite3_ctx *ctx, size_t ofs, const char *key, const unsigned char **out_ptr, uint32_t *out_len);
int shim_lite3_ctx_get_obj(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs);
int shim_lite3_ctx_get_arr(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs);

int shim_lite3_ctx_arr_append_null(lite3_ctx *ctx, size_t ofs);
int shim_lite3_ctx_arr_append_bool(lite3_ctx *ctx, size_t ofs, bool value);
int shim_lite3_ctx_arr_append_i64(lite3_ctx *ctx, size_t ofs, int64_t value);
int shim_lite3_ctx_arr_append_f64(lite3_ctx *ctx, size_t ofs, double value);
int shim_lite3_ctx_arr_append_str(lite3_ctx *ctx, size_t ofs, const char *str, size_t str_len);
int shim_lite3_ctx_arr_append_bytes(lite3_ctx *ctx, size_t ofs, const unsigned char *data, size_t data_len);
int shim_lite3_ctx_arr_append_obj(lite3_ctx *ctx, size_t ofs, size_t *out_ofs);
int shim_lite3_ctx_arr_append_arr(lite3_ctx *ctx, size_t ofs, size_t *out_ofs);

int shim_lite3_ctx_arr_get_bool(lite3_ctx *ctx, size_t ofs, uint32_t index, bool *out);
int shim_lite3_ctx_arr_get_i64(lite3_ctx *ctx, size_t ofs, uint32_t index, int64_t *out);
int shim_lite3_ctx_arr_get_f64(lite3_ctx *ctx, size_t ofs, uint32_t index, double *out);
int shim_lite3_ctx_arr_get_str(lite3_ctx *ctx, size_t ofs, uint32_t index, const char **out_ptr, uint32_t *out_len);
int shim_lite3_ctx_arr_get_bytes(lite3_ctx *ctx, size_t ofs, uint32_t index, const unsigned char **out_ptr, uint32_t *out_len);
int shim_lite3_ctx_arr_get_obj(lite3_ctx *ctx, size_t ofs, uint32_t index, size_t *out_ofs);
int shim_lite3_ctx_arr_get_arr(lite3_ctx *ctx, size_t ofs, uint32_t index, size_t *out_ofs);
int shim_lite3_ctx_arr_get_type(lite3_ctx *ctx, size_t ofs, uint32_t index);

int shim_lite3_ctx_count(lite3_ctx *ctx, size_t ofs, uint32_t *out);
int shim_lite3_ctx_import_from_buf(lite3_ctx *ctx, const unsigned char *buf, size_t buflen);
int shim_lite3_ctx_json_dec(lite3_ctx *ctx, const char *json_str, size_t json_len);

#ifdef __cplusplus
}
#endif

#endif /* LITE3_SHIM_H */
