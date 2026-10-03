/*
 * JSON backend for lite3-zig, compiled as a single translation unit.
 *
 * lite3's JSON support bundles yyjson and nibble_base64. Compiled as separate
 * objects, they would export every yyjson_* and nibble_* symbol from
 * liblite3.a and clash with a program that links its own yyjson. Here they are
 * included into one translation unit with yyjson's API made `static` and the
 * base64 functions renamed, so only lite3's own lite3_* / _lite3_* symbols
 * leave this object.
 */

#define yyjson_api static
#define nibble_base64 lite3zig_nibble_base64
#define nibble_unbase64 lite3zig_nibble_unbase64
#define nibble_base64integrity lite3zig_nibble_base64integrity

#include "../vendor/lite3/lib/yyjson/yyjson.c"
#include "../vendor/lite3/lib/nibble_base64/base64.c"
#include "../vendor/lite3/src/json_enc.c"
#include "../vendor/lite3/src/json_dec.c"

#include "lite3_shim.h"

/* JSON nesting lite3 accepts (LITE3_JSON_NESTING_DEPTH_MAX); the root is 1. */
static int json_precheck(yyjson_val *val, size_t depth)
{
    if (yyjson_is_obj(val)) {
        if (depth > LITE3_JSON_NESTING_DEPTH_MAX) return -LITE3ZIG_E_JSON_NESTING;
        yyjson_obj_iter iter = yyjson_obj_iter_with(val);
        yyjson_val *key;
        while ((key = yyjson_obj_iter_next(&iter))) {
            /* lite3 keys are NUL-terminated; "\u0000" would truncate them. */
            if (memchr(yyjson_get_str(key), 0, yyjson_get_len(key))) return -LITE3ZIG_E_JSON_KEY;
            int ret = json_precheck(yyjson_obj_iter_get_val(key), depth + 1);
            if (ret < 0) return ret;
        }
    } else if (yyjson_is_arr(val)) {
        if (depth > LITE3_JSON_NESTING_DEPTH_MAX) return -LITE3ZIG_E_JSON_NESTING;
        yyjson_arr_iter iter = yyjson_arr_iter_with(val);
        yyjson_val *item;
        while ((item = yyjson_arr_iter_next(&iter))) {
            int ret = json_precheck(item, depth + 1);
            if (ret < 0) return ret;
        }
    }
    return 0;
}

int shim_json_parse(const char *json, size_t json_len, const shim_alc *alc,
                    shim_json_diag *diag, void **out_doc)
{
    yyjson_alc yy_alc = { alc->malloc, alc->realloc, alc->free, alc->ctx };
    yyjson_read_err err;
    yyjson_doc *doc = yyjson_read_opts((char *)json, json_len, YYJSON_READ_NOFLAG, &yy_alc, &err);
    if (!doc) {
        if (err.code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) return -LITE3ZIG_E_NO_MEMORY;
        diag->code = err.code;
        diag->position = err.pos;
        diag->message = err.msg;
        return -LITE3ZIG_E_JSON_SYNTAX;
    }
    yyjson_val *root = yyjson_doc_get_root(doc);
    int ret = (yyjson_is_obj(root) || yyjson_is_arr(root)) ? json_precheck(root, 1) : -LITE3ZIG_E_JSON_ROOT;
    if (ret < 0) {
        yyjson_doc_free(doc);
        return ret;
    }
    *out_doc = doc;
    return 0;
}

int shim_json_convert(void *doc_ptr, unsigned char *buf, size_t *out_buflen, size_t bufsz)
{
    yyjson_doc *doc = doc_ptr;
    yyjson_val *root = yyjson_doc_get_root(doc);
    int ret;
    if (yyjson_is_obj(root)) {
        if (lite3_init_obj(buf, out_buflen, bufsz) < 0 ||
            _lite3_json_dec_obj(buf, out_buflen, 0, bufsz, 0, doc, root) < 0)
            ret = -1;
        else
            ret = 0;
    } else {
        if (lite3_init_arr(buf, out_buflen, bufsz) < 0 ||
            _lite3_json_dec_arr(buf, out_buflen, 0, bufsz, 0, doc, root) < 0)
            ret = -1;
        else
            ret = 0;
    }
    if (ret == 0) return 0;
    switch (errno) {
    case ENOBUFS: return -LITE3ZIG_E_NO_SPACE;
    case ENOSPC: return -LITE3ZIG_E_KEY_COLLISION;
    case ENOMEM: return -LITE3ZIG_E_NO_MEMORY;
    default: return -LITE3ZIG_E_UNKNOWN;
    }
}

void shim_json_free(void *doc)
{
    yyjson_doc_free(doc);
}
