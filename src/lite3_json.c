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

int lite3zig_json_syntax_error(const char *json_str, size_t json_len, shim_json_diag *diag)
{
    yyjson_read_err err;
    yyjson_doc *doc = yyjson_read_opts((char *)json_str, json_len, YYJSON_READ_NOFLAG, NULL, &err);
    if (doc) {
        yyjson_doc_free(doc);
        return 0;
    }
    diag->code = err.code;
    diag->position = err.pos;
    diag->message = err.msg;
    return 1;
}
