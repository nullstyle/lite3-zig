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
