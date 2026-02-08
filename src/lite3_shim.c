/**
 * lite3_shim.c - C shim implementation for lite3 inline functions.
 *
 * This file wraps the static inline functions from lite3.h and
 * lite3_context_api.h as proper extern C functions, avoiding the
 * alignment and flexible-array-member issues that Zig's cImport
 * cannot handle.
 */
#include "lite3.h"
#include "lite3_context_api.h"
#include "lite3_shim.h"
#include <string.h>
#include <errno.h>
#include <stdlib.h>

/* ---- Buffer API: Object get ---- */

int shim_lite3_get_bool(const unsigned char *buf, size_t buflen, size_t ofs,
                        const char *key, bool *out)
{
    return lite3_get_bool(buf, buflen, ofs, key, out);
}

int shim_lite3_get_i64(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, int64_t *out)
{
    return lite3_get_i64(buf, buflen, ofs, key, out);
}

int shim_lite3_get_f64(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, double *out)
{
    return lite3_get_f64(buf, buflen, ofs, key, out);
}

int shim_lite3_get_str(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = lite3_get_str(buf, buflen, ofs, key, &s);
    if (ret >= 0) {
        const char *p = LITE3_STR(buf, s);
        if (p) {
            *out_ptr = p;
            *out_len = s.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_get_bytes(const unsigned char *buf, size_t buflen, size_t ofs,
                         const char *key, const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = lite3_get_bytes(buf, buflen, ofs, key, &b);
    if (ret >= 0) {
        const unsigned char *p = LITE3_BYTES(buf, b);
        if (p) {
            *out_ptr = p;
            *out_len = b.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_get_obj(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, size_t *out_ofs)
{
    return lite3_get_obj(buf, buflen, ofs, key, out_ofs);
}

int shim_lite3_get_arr(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, size_t *out_ofs)
{
    return lite3_get_arr(buf, buflen, ofs, key, out_ofs);
}

int shim_lite3_get_type(const unsigned char *buf, size_t buflen, size_t ofs,
                        const char *key)
{
    return (int)lite3_get_type(buf, buflen, ofs, key);
}

int shim_lite3_exists(const unsigned char *buf, size_t buflen, size_t ofs,
                      const char *key)
{
    return lite3_exists(buf, buflen, ofs, key) ? 1 : 0;
}

/* ---- Buffer API: Object set ---- */

int shim_lite3_set_null(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                        size_t bufsz, const char *key)
{
    return lite3_set_null(buf, inout_buflen, ofs, bufsz, key);
}

int shim_lite3_set_bool(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                        size_t bufsz, const char *key, bool value)
{
    return lite3_set_bool(buf, inout_buflen, ofs, bufsz, key, value);
}

int shim_lite3_set_i64(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, int64_t value)
{
    return lite3_set_i64(buf, inout_buflen, ofs, bufsz, key, value);
}

int shim_lite3_set_f64(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, double value)
{
    return lite3_set_f64(buf, inout_buflen, ofs, bufsz, key, value);
}

int shim_lite3_set_str(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, const char *str, size_t str_len)
{
    return lite3_set_str_n(buf, inout_buflen, ofs, bufsz, key, str, str_len);
}

int shim_lite3_set_bytes(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                         size_t bufsz, const char *key, const unsigned char *data, size_t data_len)
{
    return lite3_set_bytes(buf, inout_buflen, ofs, bufsz, key, data, data_len);
}

int shim_lite3_set_obj(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, size_t *out_ofs)
{
    return lite3_set_obj(buf, inout_buflen, ofs, bufsz, key, out_ofs);
}

int shim_lite3_set_arr(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, size_t *out_ofs)
{
    return lite3_set_arr(buf, inout_buflen, ofs, bufsz, key, out_ofs);
}

/* ---- Buffer API: Array append ---- */

int shim_lite3_arr_append_null(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz)
{
    return lite3_arr_append_null(buf, inout_buflen, ofs, bufsz);
}

int shim_lite3_arr_append_bool(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, bool value)
{
    return lite3_arr_append_bool(buf, inout_buflen, ofs, bufsz, value);
}

int shim_lite3_arr_append_i64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, int64_t value)
{
    return lite3_arr_append_i64(buf, inout_buflen, ofs, bufsz, value);
}

int shim_lite3_arr_append_f64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, double value)
{
    return lite3_arr_append_f64(buf, inout_buflen, ofs, bufsz, value);
}

int shim_lite3_arr_append_str(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *str, size_t str_len)
{
    return lite3_arr_append_str_n(buf, inout_buflen, ofs, bufsz, str, str_len);
}

int shim_lite3_arr_append_bytes(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const unsigned char *data, size_t data_len)
{
    return lite3_arr_append_bytes(buf, inout_buflen, ofs, bufsz, data, data_len);
}

int shim_lite3_arr_append_obj(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, size_t *out_ofs)
{
    return lite3_arr_append_obj(buf, inout_buflen, ofs, bufsz, out_ofs);
}

int shim_lite3_arr_append_arr(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, size_t *out_ofs)
{
    return lite3_arr_append_arr(buf, inout_buflen, ofs, bufsz, out_ofs);
}

/* ---- Buffer API: Array get ---- */

int shim_lite3_arr_get_bool(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, bool *out)
{
    return lite3_arr_get_bool(buf, buflen, ofs, index, out);
}

int shim_lite3_arr_get_i64(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, int64_t *out)
{
    return lite3_arr_get_i64(buf, buflen, ofs, index, out);
}

int shim_lite3_arr_get_f64(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, double *out)
{
    return lite3_arr_get_f64(buf, buflen, ofs, index, out);
}

int shim_lite3_arr_get_str(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index,
                           const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = lite3_arr_get_str(buf, buflen, ofs, index, &s);
    if (ret >= 0) {
        const char *p = LITE3_STR(buf, s);
        if (p) {
            *out_ptr = p;
            *out_len = s.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_arr_get_bytes(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index,
                             const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = lite3_arr_get_bytes(buf, buflen, ofs, index, &b);
    if (ret >= 0) {
        const unsigned char *p = LITE3_BYTES(buf, b);
        if (p) {
            *out_ptr = p;
            *out_len = b.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_arr_get_obj(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, size_t *out_ofs)
{
    return lite3_arr_get_obj(buf, buflen, ofs, index, out_ofs);
}

int shim_lite3_arr_get_arr(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, size_t *out_ofs)
{
    return lite3_arr_get_arr(buf, buflen, ofs, index, out_ofs);
}

int shim_lite3_arr_get_type(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index)
{
    return (int)lite3_arr_get_type(buf, buflen, ofs, index);
}

/* ---- Buffer API: Utility ---- */

int shim_lite3_count(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t *out)
{
    return lite3_count((unsigned char *)buf, buflen, ofs, out);
}

/* ---- Buffer API: Iterator ---- */

_Static_assert(sizeof(shim_lite3_iter) >= sizeof(lite3_iter), "shim_lite3_iter too small");

int shim_lite3_iter_create(const unsigned char *buf, size_t buflen, size_t ofs, shim_lite3_iter *iter)
{
    return lite3_iter_create(buf, buflen, ofs, (lite3_iter *)iter);
}

int shim_lite3_iter_next(const unsigned char *buf, size_t buflen, shim_lite3_iter *iter,
                         const char **key_ptr, uint32_t *key_len, size_t *val_ofs)
{
    lite3_str key;
    int ret = lite3_iter_next(buf, buflen, (lite3_iter *)iter, &key, val_ofs);
    if (ret == LITE3_ITER_DONE) return 1;
    if (ret < 0) return ret;
    if (key.ptr != NULL) {
        const char *p = LITE3_STR(buf, key);
        *key_ptr = p;
        *key_len = key.len;
    } else {
        *key_ptr = NULL;
        *key_len = 0;
    }
    return 0;
}

/* ---- Buffer API: JSON ---- */

int shim_lite3_json_dec(unsigned char *buf, size_t *out_buflen, size_t bufsz,
                        const char *json_str, size_t json_len)
{
    return lite3_json_dec(buf, out_buflen, bufsz, json_str, json_len);
}

char *shim_lite3_json_enc(const unsigned char *buf, size_t buflen, size_t ofs, size_t *out_len)
{
    return lite3_json_enc(buf, buflen, ofs, out_len);
}

char *shim_lite3_json_enc_pretty(const unsigned char *buf, size_t buflen, size_t ofs, size_t *out_len)
{
    return lite3_json_enc_pretty(buf, buflen, ofs, out_len);
}

int64_t shim_lite3_json_enc_buf(const unsigned char *buf, size_t buflen, size_t ofs,
                                char *json_buf, size_t json_bufsz)
{
    return lite3_json_enc_buf(buf, buflen, ofs, json_buf, json_bufsz);
}

/* ---- Context API ---- */

lite3_ctx *shim_lite3_ctx_create(void) { return lite3_ctx_create(); }
lite3_ctx *shim_lite3_ctx_create_with_size(size_t bufsz) { return lite3_ctx_create_with_size(bufsz); }
lite3_ctx *shim_lite3_ctx_create_from_buf(const unsigned char *buf, size_t buflen) { return lite3_ctx_create_from_buf(buf, buflen); }
void shim_lite3_ctx_destroy(lite3_ctx *ctx) { lite3_ctx_destroy(ctx); }
unsigned char *shim_lite3_ctx_buf(lite3_ctx *ctx) { return ctx->buf; }
size_t shim_lite3_ctx_buflen(lite3_ctx *ctx) { return ctx->buflen; }
size_t shim_lite3_ctx_bufsz(lite3_ctx *ctx) { return ctx->bufsz; }

int shim_lite3_ctx_init_obj(lite3_ctx *ctx) { return lite3_ctx_init_obj(ctx); }
int shim_lite3_ctx_init_arr(lite3_ctx *ctx) { return lite3_ctx_init_arr(ctx); }

int shim_lite3_ctx_set_null(lite3_ctx *ctx, size_t ofs, const char *key) { return lite3_ctx_set_null(ctx, ofs, key); }
int shim_lite3_ctx_set_bool(lite3_ctx *ctx, size_t ofs, const char *key, bool value) { return lite3_ctx_set_bool(ctx, ofs, key, value); }
int shim_lite3_ctx_set_i64(lite3_ctx *ctx, size_t ofs, const char *key, int64_t value) { return lite3_ctx_set_i64(ctx, ofs, key, value); }
int shim_lite3_ctx_set_f64(lite3_ctx *ctx, size_t ofs, const char *key, double value) { return lite3_ctx_set_f64(ctx, ofs, key, value); }
int shim_lite3_ctx_set_str(lite3_ctx *ctx, size_t ofs, const char *key, const char *str, size_t str_len) { return lite3_ctx_set_str_n(ctx, ofs, key, str, str_len); }
int shim_lite3_ctx_set_bytes(lite3_ctx *ctx, size_t ofs, const char *key, const unsigned char *data, size_t data_len) { return lite3_ctx_set_bytes(ctx, ofs, key, data, data_len); }
int shim_lite3_ctx_set_obj(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return lite3_ctx_set_obj(ctx, ofs, key, out_ofs); }
int shim_lite3_ctx_set_arr(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return lite3_ctx_set_arr(ctx, ofs, key, out_ofs); }

int shim_lite3_ctx_get_type(lite3_ctx *ctx, size_t ofs, const char *key) { return (int)lite3_ctx_get_type(ctx, ofs, key); }
int shim_lite3_ctx_exists(lite3_ctx *ctx, size_t ofs, const char *key) { return lite3_ctx_exists(ctx, ofs, key) ? 1 : 0; }
int shim_lite3_ctx_get_bool(lite3_ctx *ctx, size_t ofs, const char *key, bool *out) { return lite3_ctx_get_bool(ctx, ofs, key, out); }
int shim_lite3_ctx_get_i64(lite3_ctx *ctx, size_t ofs, const char *key, int64_t *out) { return lite3_ctx_get_i64(ctx, ofs, key, out); }
int shim_lite3_ctx_get_f64(lite3_ctx *ctx, size_t ofs, const char *key, double *out) { return lite3_ctx_get_f64(ctx, ofs, key, out); }

int shim_lite3_ctx_get_str(lite3_ctx *ctx, size_t ofs, const char *key, const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = lite3_ctx_get_str(ctx, ofs, key, &s);
    if (ret >= 0) {
        const char *p = LITE3_STR(ctx->buf, s);
        if (p) {
            *out_ptr = p;
            *out_len = s.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_ctx_get_bytes(lite3_ctx *ctx, size_t ofs, const char *key, const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = lite3_ctx_get_bytes(ctx, ofs, key, &b);
    if (ret >= 0) {
        const unsigned char *p = LITE3_BYTES(ctx->buf, b);
        if (p) {
            *out_ptr = p;
            *out_len = b.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_ctx_get_obj(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return lite3_ctx_get_obj(ctx, ofs, key, out_ofs); }
int shim_lite3_ctx_get_arr(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return lite3_ctx_get_arr(ctx, ofs, key, out_ofs); }

int shim_lite3_ctx_arr_append_null(lite3_ctx *ctx, size_t ofs) { return lite3_ctx_arr_append_null(ctx, ofs); }
int shim_lite3_ctx_arr_append_bool(lite3_ctx *ctx, size_t ofs, bool value) { return lite3_ctx_arr_append_bool(ctx, ofs, value); }
int shim_lite3_ctx_arr_append_i64(lite3_ctx *ctx, size_t ofs, int64_t value) { return lite3_ctx_arr_append_i64(ctx, ofs, value); }
int shim_lite3_ctx_arr_append_f64(lite3_ctx *ctx, size_t ofs, double value) { return lite3_ctx_arr_append_f64(ctx, ofs, value); }
int shim_lite3_ctx_arr_append_str(lite3_ctx *ctx, size_t ofs, const char *str, size_t str_len) { return lite3_ctx_arr_append_str_n(ctx, ofs, str, str_len); }
int shim_lite3_ctx_arr_append_bytes(lite3_ctx *ctx, size_t ofs, const unsigned char *data, size_t data_len) { return lite3_ctx_arr_append_bytes(ctx, ofs, data, data_len); }
int shim_lite3_ctx_arr_append_obj(lite3_ctx *ctx, size_t ofs, size_t *out_ofs) { return lite3_ctx_arr_append_obj(ctx, ofs, out_ofs); }
int shim_lite3_ctx_arr_append_arr(lite3_ctx *ctx, size_t ofs, size_t *out_ofs) { return lite3_ctx_arr_append_arr(ctx, ofs, out_ofs); }

int shim_lite3_ctx_arr_get_bool(lite3_ctx *ctx, size_t ofs, uint32_t index, bool *out) { return lite3_ctx_arr_get_bool(ctx, ofs, index, out); }
int shim_lite3_ctx_arr_get_i64(lite3_ctx *ctx, size_t ofs, uint32_t index, int64_t *out) { return lite3_ctx_arr_get_i64(ctx, ofs, index, out); }
int shim_lite3_ctx_arr_get_f64(lite3_ctx *ctx, size_t ofs, uint32_t index, double *out) { return lite3_ctx_arr_get_f64(ctx, ofs, index, out); }

int shim_lite3_ctx_arr_get_str(lite3_ctx *ctx, size_t ofs, uint32_t index, const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = lite3_ctx_arr_get_str(ctx, ofs, index, &s);
    if (ret >= 0) {
        const char *p = LITE3_STR(ctx->buf, s);
        if (p) {
            *out_ptr = p;
            *out_len = s.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_ctx_arr_get_bytes(lite3_ctx *ctx, size_t ofs, uint32_t index, const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = lite3_ctx_arr_get_bytes(ctx, ofs, index, &b);
    if (ret >= 0) {
        const unsigned char *p = LITE3_BYTES(ctx->buf, b);
        if (p) {
            *out_ptr = p;
            *out_len = b.len;
        } else {
            *out_ptr = NULL;
            *out_len = 0;
        }
    }
    return ret;
}

int shim_lite3_ctx_arr_get_obj(lite3_ctx *ctx, size_t ofs, uint32_t index, size_t *out_ofs) { return lite3_ctx_arr_get_obj(ctx, ofs, index, out_ofs); }
int shim_lite3_ctx_arr_get_arr(lite3_ctx *ctx, size_t ofs, uint32_t index, size_t *out_ofs) { return lite3_ctx_arr_get_arr(ctx, ofs, index, out_ofs); }
int shim_lite3_ctx_arr_get_type(lite3_ctx *ctx, size_t ofs, uint32_t index) { return (int)lite3_ctx_arr_get_type(ctx, ofs, index); }

int shim_lite3_ctx_count(lite3_ctx *ctx, size_t ofs, uint32_t *out) { return lite3_ctx_count(ctx, ofs, out); }
int shim_lite3_ctx_import_from_buf(lite3_ctx *ctx, const unsigned char *buf, size_t buflen) { return lite3_ctx_import_from_buf(ctx, buf, buflen); }

int shim_lite3_ctx_json_dec(lite3_ctx *ctx, const char *json_str, size_t json_len) { return lite3_ctx_json_dec(ctx, json_str, json_len); }
