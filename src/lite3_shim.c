/**
 * lite3_shim.c - C shim implementation (see lite3_shim.h for the conventions).
 */
#include "lite3.h"
#include "lite3_context_api.h"
#include "lite3_shim.h"
#include <string.h>
#include <errno.h>
#include <stdlib.h>

/* ---- Status translation ---- */

static int status_from_errno(int e)
{
    switch (e) {
    case ENOENT: return LITE3ZIG_E_NOT_FOUND;
    case EINVAL: return LITE3ZIG_E_INVALID;
    case ENOBUFS:
    case EMSGSIZE: return LITE3ZIG_E_NO_SPACE;
    case EBADMSG: return LITE3ZIG_E_CORRUPT;
    case EFAULT: return LITE3ZIG_E_OUT_OF_BOUNDS;
    case ENOMEM: return LITE3ZIG_E_NO_MEMORY;
    case EOVERFLOW: return LITE3ZIG_E_OVERFLOW;
    case EIO: return LITE3ZIG_E_JSON_WRITE;
    default: return LITE3ZIG_E_UNKNOWN;
    }
}

/* Pass a lite3 return value through, turning failures into -status. Must be
   applied directly to the lite3 call so errno is read before anything else
   can change it. */
static inline int st(int ret)
{
    return ret < 0 ? -status_from_errno(errno) : ret;
}

static inline void out_str(const unsigned char *buf, lite3_str s, const char **out_ptr, uint32_t *out_len)
{
    const char *p = LITE3_STR(buf, s);
    *out_ptr = p;
    *out_len = p ? s.len : 0;
}

static inline void out_bytes(const unsigned char *buf, lite3_bytes b, const unsigned char **out_ptr, uint32_t *out_len)
{
    const unsigned char *p = LITE3_BYTES(buf, b);
    *out_ptr = p;
    *out_len = p ? b.len : 0;
}

/* ---- Buffer API: Object get ---- */

int shim_lite3_get_bool(const unsigned char *buf, size_t buflen, size_t ofs, const char *key, bool *out)
{
    return st(lite3_get_bool(buf, buflen, ofs, key, out));
}

int shim_lite3_get_i64(const unsigned char *buf, size_t buflen, size_t ofs, const char *key, int64_t *out)
{
    return st(lite3_get_i64(buf, buflen, ofs, key, out));
}

int shim_lite3_get_f64(const unsigned char *buf, size_t buflen, size_t ofs, const char *key, double *out)
{
    return st(lite3_get_f64(buf, buflen, ofs, key, out));
}

int shim_lite3_get_str(const unsigned char *buf, size_t buflen, size_t ofs,
                       const char *key, const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = st(lite3_get_str(buf, buflen, ofs, key, &s));
    if (ret >= 0) out_str(buf, s, out_ptr, out_len);
    return ret;
}

int shim_lite3_get_bytes(const unsigned char *buf, size_t buflen, size_t ofs,
                         const char *key, const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = st(lite3_get_bytes(buf, buflen, ofs, key, &b));
    if (ret >= 0) out_bytes(buf, b, out_ptr, out_len);
    return ret;
}

int shim_lite3_get_obj(const unsigned char *buf, size_t buflen, size_t ofs, const char *key, size_t *out_ofs)
{
    return st(lite3_get_obj(buf, buflen, ofs, key, out_ofs));
}

int shim_lite3_get_arr(const unsigned char *buf, size_t buflen, size_t ofs, const char *key, size_t *out_ofs)
{
    return st(lite3_get_arr(buf, buflen, ofs, key, out_ofs));
}

/* lite3_get_type()/lite3_exists() collapse every failure (corrupt data, wrong
   container type) into LITE3_TYPE_INVALID/false. Use the underlying lookup so
   only a genuinely missing key reads as "not found". */
int shim_lite3_get_type(const unsigned char *buf, size_t buflen, size_t ofs, const char *key)
{
    int ret = st(_lite3_verify_obj_get(buf, buflen, ofs, key));
    if (ret < 0) return ret;
    lite3_val *val;
    ret = st(lite3_get_impl(buf, buflen, ofs, key, lite3_get_key_data(key), &val));
    if (ret < 0) return ret;
    return (int)val->type;
}

int shim_lite3_exists(const unsigned char *buf, size_t buflen, size_t ofs, const char *key)
{
    int ret = shim_lite3_get_type(buf, buflen, ofs, key);
    if (ret >= 0) return 1;
    return ret == -LITE3ZIG_E_NOT_FOUND ? 0 : ret;
}

/* ---- Buffer API: Object set ---- */

int shim_lite3_set_null(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *key)
{
    return st(lite3_set_null(buf, inout_buflen, ofs, bufsz, key));
}

int shim_lite3_set_bool(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *key, bool value)
{
    return st(lite3_set_bool(buf, inout_buflen, ofs, bufsz, key, value));
}

int shim_lite3_set_i64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *key, int64_t value)
{
    return st(lite3_set_i64(buf, inout_buflen, ofs, bufsz, key, value));
}

int shim_lite3_set_f64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *key, double value)
{
    return st(lite3_set_f64(buf, inout_buflen, ofs, bufsz, key, value));
}

int shim_lite3_set_str(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                       size_t bufsz, const char *key, const char *str, size_t str_len)
{
    return st(lite3_set_str_n(buf, inout_buflen, ofs, bufsz, key, str, str_len));
}

int shim_lite3_set_bytes(unsigned char *buf, size_t *inout_buflen, size_t ofs,
                         size_t bufsz, const char *key, const unsigned char *data, size_t data_len)
{
    return st(lite3_set_bytes(buf, inout_buflen, ofs, bufsz, key, data, data_len));
}

int shim_lite3_set_obj(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *key, size_t *out_ofs)
{
    return st(lite3_set_obj(buf, inout_buflen, ofs, bufsz, key, out_ofs));
}

int shim_lite3_set_arr(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *key, size_t *out_ofs)
{
    return st(lite3_set_arr(buf, inout_buflen, ofs, bufsz, key, out_ofs));
}

/* ---- Buffer API: Array append ---- */

int shim_lite3_arr_append_null(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz)
{
    return st(lite3_arr_append_null(buf, inout_buflen, ofs, bufsz));
}

int shim_lite3_arr_append_bool(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, bool value)
{
    return st(lite3_arr_append_bool(buf, inout_buflen, ofs, bufsz, value));
}

int shim_lite3_arr_append_i64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, int64_t value)
{
    return st(lite3_arr_append_i64(buf, inout_buflen, ofs, bufsz, value));
}

int shim_lite3_arr_append_f64(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, double value)
{
    return st(lite3_arr_append_f64(buf, inout_buflen, ofs, bufsz, value));
}

int shim_lite3_arr_append_str(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const char *str, size_t str_len)
{
    return st(lite3_arr_append_str_n(buf, inout_buflen, ofs, bufsz, str, str_len));
}

int shim_lite3_arr_append_bytes(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, const unsigned char *data, size_t data_len)
{
    return st(lite3_arr_append_bytes(buf, inout_buflen, ofs, bufsz, data, data_len));
}

int shim_lite3_arr_append_obj(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, size_t *out_ofs)
{
    return st(lite3_arr_append_obj(buf, inout_buflen, ofs, bufsz, out_ofs));
}

int shim_lite3_arr_append_arr(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz, size_t *out_ofs)
{
    return st(lite3_arr_append_arr(buf, inout_buflen, ofs, bufsz, out_ofs));
}

/* ---- Buffer API: Array get ---- */

int shim_lite3_arr_get_bool(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, bool *out)
{
    return st(lite3_arr_get_bool(buf, buflen, ofs, index, out));
}

int shim_lite3_arr_get_i64(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, int64_t *out)
{
    return st(lite3_arr_get_i64(buf, buflen, ofs, index, out));
}

int shim_lite3_arr_get_f64(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, double *out)
{
    return st(lite3_arr_get_f64(buf, buflen, ofs, index, out));
}

int shim_lite3_arr_get_str(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index,
                           const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = st(lite3_arr_get_str(buf, buflen, ofs, index, &s));
    if (ret >= 0) out_str(buf, s, out_ptr, out_len);
    return ret;
}

int shim_lite3_arr_get_bytes(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index,
                             const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = st(lite3_arr_get_bytes(buf, buflen, ofs, index, &b));
    if (ret >= 0) out_bytes(buf, b, out_ptr, out_len);
    return ret;
}

int shim_lite3_arr_get_obj(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, size_t *out_ofs)
{
    return st(lite3_arr_get_obj(buf, buflen, ofs, index, out_ofs));
}

int shim_lite3_arr_get_arr(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index, size_t *out_ofs)
{
    return st(lite3_arr_get_arr(buf, buflen, ofs, index, out_ofs));
}

/* See shim_lite3_get_type(). */
int shim_lite3_arr_get_type(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t index)
{
    int ret = st(_lite3_verify_arr_get(buf, buflen, ofs));
    if (ret < 0) return ret;
    lite3_val *val;
    ret = st(_lite3_get_by_index(buf, buflen, ofs, index, &val));
    if (ret < 0) return ret;
    return (int)val->type;
}

/* ---- Buffer API: Utility ---- */

int shim_lite3_count(const unsigned char *buf, size_t buflen, size_t ofs, uint32_t *out)
{
    return st(lite3_count((unsigned char *)buf, buflen, ofs, out));
}

/* ---- Buffer API: Iterator ---- */

_Static_assert(sizeof(shim_lite3_iter) >= sizeof(lite3_iter), "shim_lite3_iter too small");
_Static_assert(_Alignof(shim_lite3_iter) >= _Alignof(lite3_iter), "shim_lite3_iter under-aligned");

int shim_lite3_iter_create(const unsigned char *buf, size_t buflen, size_t ofs, shim_lite3_iter *iter)
{
    return st(lite3_iter_create(buf, buflen, ofs, (lite3_iter *)iter));
}

int shim_lite3_iter_next(const unsigned char *buf, size_t buflen, shim_lite3_iter *iter,
                         const char **key_ptr, uint32_t *key_len, size_t *val_ofs)
{
    /* lite3_iter_next() only writes the key for objects; for arrays it must
       read as "no key", never as whatever the stack held. */
    lite3_str key = {0};
    int ret = st(lite3_iter_next(buf, buflen, (lite3_iter *)iter, &key, val_ofs));
    *key_ptr = NULL;
    *key_len = 0;
    if (ret < 0) return ret;
    if (ret == LITE3_ITER_DONE) return 1;
    if (key.ptr != NULL) out_str(buf, key, key_ptr, key_len);
    return 0;
}

/* ---- JSON ---- */

/* Decode failures from yyjson's parser and from lite3 (nesting limit, NUL in
   key, scalar root) all surface as EINVAL. Re-parse on that path only, to
   tell a syntax error (with position) from the rest. */
static int json_dec_status(int ret, const char *json_str, size_t json_len, shim_json_diag *diag)
{
    if (ret != -LITE3ZIG_E_INVALID) return ret;
    shim_json_diag local;
    if (lite3zig_json_syntax_error(json_str, json_len, diag ? diag : &local)) return -LITE3ZIG_E_JSON_SYNTAX;
    return ret;
}

int shim_lite3_json_dec(unsigned char *buf, size_t *out_buflen, size_t bufsz,
                        const char *json_str, size_t json_len, shim_json_diag *diag)
{
    int ret = st(lite3_json_dec(buf, out_buflen, bufsz, json_str, json_len));
    return json_dec_status(ret, json_str, json_len, diag);
}

int shim_lite3_json_enc(const unsigned char *buf, size_t buflen, size_t ofs, char **out, size_t *out_len)
{
    errno = 0;
    char *s = lite3_json_enc(buf, buflen, ofs, out_len);
    if (!s) return errno ? -status_from_errno(errno) : -LITE3ZIG_E_UNKNOWN;
    *out = s;
    return 0;
}

int shim_lite3_json_enc_pretty(const unsigned char *buf, size_t buflen, size_t ofs, char **out, size_t *out_len)
{
    errno = 0;
    char *s = lite3_json_enc_pretty(buf, buflen, ofs, out_len);
    if (!s) return errno ? -status_from_errno(errno) : -LITE3ZIG_E_UNKNOWN;
    *out = s;
    return 0;
}

/* lite3_json_enc_buf() reports a too-small output buffer as a generic write
   error (EIO) and gives no way to learn the needed size. Encode to a
   temporary string instead, which knows its exact length. */
int shim_lite3_json_enc_buf(const unsigned char *buf, size_t buflen, size_t ofs,
                            char *json_buf, size_t json_bufsz, size_t *out_len)
{
    char *s;
    size_t len;
    int ret = shim_lite3_json_enc(buf, buflen, ofs, &s, &len);
    if (ret < 0) return ret;
    *out_len = len;
    if (len > json_bufsz) {
        free(s);
        return -LITE3ZIG_E_NO_SPACE;
    }
    memcpy(json_buf, s, len);
    free(s);
    return 0;
}

/* ---- Context API ---- */

static int ctx_out(lite3_ctx *ctx, lite3_ctx **out)
{
    if (!ctx) return errno ? -status_from_errno(errno) : -LITE3ZIG_E_NO_MEMORY;
    *out = ctx;
    return 0;
}

int shim_lite3_ctx_create(lite3_ctx **out)
{
    errno = 0;
    return ctx_out(lite3_ctx_create(), out);
}

int shim_lite3_ctx_create_with_size(size_t bufsz, lite3_ctx **out)
{
    errno = 0;
    return ctx_out(lite3_ctx_create_with_size(bufsz), out);
}

int shim_lite3_ctx_create_from_buf(const unsigned char *buf, size_t buflen, lite3_ctx **out)
{
    errno = 0;
    return ctx_out(lite3_ctx_create_from_buf(buf, buflen), out);
}

void shim_lite3_ctx_destroy(lite3_ctx *ctx) { lite3_ctx_destroy(ctx); }
unsigned char *shim_lite3_ctx_buf(lite3_ctx *ctx) { return ctx->buf; }
size_t shim_lite3_ctx_buflen(lite3_ctx *ctx) { return ctx->buflen; }
size_t shim_lite3_ctx_bufsz(lite3_ctx *ctx) { return ctx->bufsz; }

int shim_lite3_ctx_init_obj(lite3_ctx *ctx) { return st(lite3_ctx_init_obj(ctx)); }
int shim_lite3_ctx_init_arr(lite3_ctx *ctx) { return st(lite3_ctx_init_arr(ctx)); }

int shim_lite3_ctx_set_null(lite3_ctx *ctx, size_t ofs, const char *key) { return st(lite3_ctx_set_null(ctx, ofs, key)); }
int shim_lite3_ctx_set_bool(lite3_ctx *ctx, size_t ofs, const char *key, bool value) { return st(lite3_ctx_set_bool(ctx, ofs, key, value)); }
int shim_lite3_ctx_set_i64(lite3_ctx *ctx, size_t ofs, const char *key, int64_t value) { return st(lite3_ctx_set_i64(ctx, ofs, key, value)); }
int shim_lite3_ctx_set_f64(lite3_ctx *ctx, size_t ofs, const char *key, double value) { return st(lite3_ctx_set_f64(ctx, ofs, key, value)); }
int shim_lite3_ctx_set_str(lite3_ctx *ctx, size_t ofs, const char *key, const char *str, size_t str_len) { return st(lite3_ctx_set_str_n(ctx, ofs, key, str, str_len)); }
int shim_lite3_ctx_set_bytes(lite3_ctx *ctx, size_t ofs, const char *key, const unsigned char *data, size_t data_len) { return st(lite3_ctx_set_bytes(ctx, ofs, key, data, data_len)); }
int shim_lite3_ctx_set_obj(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return st(lite3_ctx_set_obj(ctx, ofs, key, out_ofs)); }
int shim_lite3_ctx_set_arr(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return st(lite3_ctx_set_arr(ctx, ofs, key, out_ofs)); }

int shim_lite3_ctx_get_type(lite3_ctx *ctx, size_t ofs, const char *key) { return shim_lite3_get_type(ctx->buf, ctx->buflen, ofs, key); }
int shim_lite3_ctx_exists(lite3_ctx *ctx, size_t ofs, const char *key) { return shim_lite3_exists(ctx->buf, ctx->buflen, ofs, key); }
int shim_lite3_ctx_get_bool(lite3_ctx *ctx, size_t ofs, const char *key, bool *out) { return st(lite3_ctx_get_bool(ctx, ofs, key, out)); }
int shim_lite3_ctx_get_i64(lite3_ctx *ctx, size_t ofs, const char *key, int64_t *out) { return st(lite3_ctx_get_i64(ctx, ofs, key, out)); }
int shim_lite3_ctx_get_f64(lite3_ctx *ctx, size_t ofs, const char *key, double *out) { return st(lite3_ctx_get_f64(ctx, ofs, key, out)); }

int shim_lite3_ctx_get_str(lite3_ctx *ctx, size_t ofs, const char *key, const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = st(lite3_ctx_get_str(ctx, ofs, key, &s));
    if (ret >= 0) out_str(ctx->buf, s, out_ptr, out_len);
    return ret;
}

int shim_lite3_ctx_get_bytes(lite3_ctx *ctx, size_t ofs, const char *key, const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = st(lite3_ctx_get_bytes(ctx, ofs, key, &b));
    if (ret >= 0) out_bytes(ctx->buf, b, out_ptr, out_len);
    return ret;
}

int shim_lite3_ctx_get_obj(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return st(lite3_ctx_get_obj(ctx, ofs, key, out_ofs)); }
int shim_lite3_ctx_get_arr(lite3_ctx *ctx, size_t ofs, const char *key, size_t *out_ofs) { return st(lite3_ctx_get_arr(ctx, ofs, key, out_ofs)); }

int shim_lite3_ctx_arr_append_null(lite3_ctx *ctx, size_t ofs) { return st(lite3_ctx_arr_append_null(ctx, ofs)); }
int shim_lite3_ctx_arr_append_bool(lite3_ctx *ctx, size_t ofs, bool value) { return st(lite3_ctx_arr_append_bool(ctx, ofs, value)); }
int shim_lite3_ctx_arr_append_i64(lite3_ctx *ctx, size_t ofs, int64_t value) { return st(lite3_ctx_arr_append_i64(ctx, ofs, value)); }
int shim_lite3_ctx_arr_append_f64(lite3_ctx *ctx, size_t ofs, double value) { return st(lite3_ctx_arr_append_f64(ctx, ofs, value)); }
int shim_lite3_ctx_arr_append_str(lite3_ctx *ctx, size_t ofs, const char *str, size_t str_len) { return st(lite3_ctx_arr_append_str_n(ctx, ofs, str, str_len)); }
int shim_lite3_ctx_arr_append_bytes(lite3_ctx *ctx, size_t ofs, const unsigned char *data, size_t data_len) { return st(lite3_ctx_arr_append_bytes(ctx, ofs, data, data_len)); }
int shim_lite3_ctx_arr_append_obj(lite3_ctx *ctx, size_t ofs, size_t *out_ofs) { return st(lite3_ctx_arr_append_obj(ctx, ofs, out_ofs)); }
int shim_lite3_ctx_arr_append_arr(lite3_ctx *ctx, size_t ofs, size_t *out_ofs) { return st(lite3_ctx_arr_append_arr(ctx, ofs, out_ofs)); }

int shim_lite3_ctx_arr_get_bool(lite3_ctx *ctx, size_t ofs, uint32_t index, bool *out) { return st(lite3_ctx_arr_get_bool(ctx, ofs, index, out)); }
int shim_lite3_ctx_arr_get_i64(lite3_ctx *ctx, size_t ofs, uint32_t index, int64_t *out) { return st(lite3_ctx_arr_get_i64(ctx, ofs, index, out)); }
int shim_lite3_ctx_arr_get_f64(lite3_ctx *ctx, size_t ofs, uint32_t index, double *out) { return st(lite3_ctx_arr_get_f64(ctx, ofs, index, out)); }

int shim_lite3_ctx_arr_get_str(lite3_ctx *ctx, size_t ofs, uint32_t index, const char **out_ptr, uint32_t *out_len)
{
    lite3_str s;
    int ret = st(lite3_ctx_arr_get_str(ctx, ofs, index, &s));
    if (ret >= 0) out_str(ctx->buf, s, out_ptr, out_len);
    return ret;
}

int shim_lite3_ctx_arr_get_bytes(lite3_ctx *ctx, size_t ofs, uint32_t index, const unsigned char **out_ptr, uint32_t *out_len)
{
    lite3_bytes b;
    int ret = st(lite3_ctx_arr_get_bytes(ctx, ofs, index, &b));
    if (ret >= 0) out_bytes(ctx->buf, b, out_ptr, out_len);
    return ret;
}

int shim_lite3_ctx_arr_get_obj(lite3_ctx *ctx, size_t ofs, uint32_t index, size_t *out_ofs) { return st(lite3_ctx_arr_get_obj(ctx, ofs, index, out_ofs)); }
int shim_lite3_ctx_arr_get_arr(lite3_ctx *ctx, size_t ofs, uint32_t index, size_t *out_ofs) { return st(lite3_ctx_arr_get_arr(ctx, ofs, index, out_ofs)); }
int shim_lite3_ctx_arr_get_type(lite3_ctx *ctx, size_t ofs, uint32_t index) { return shim_lite3_arr_get_type(ctx->buf, ctx->buflen, ofs, index); }

int shim_lite3_ctx_count(lite3_ctx *ctx, size_t ofs, uint32_t *out) { return st(lite3_ctx_count(ctx, ofs, out)); }
int shim_lite3_ctx_import_from_buf(lite3_ctx *ctx, const unsigned char *buf, size_t buflen) { return st(lite3_ctx_import_from_buf(ctx, buf, buflen)); }

int shim_lite3_ctx_json_dec(lite3_ctx *ctx, const char *json_str, size_t json_len, shim_json_diag *diag)
{
    int ret = st(lite3_ctx_json_dec(ctx, json_str, json_len));
    return json_dec_status(ret, json_str, json_len, diag);
}
