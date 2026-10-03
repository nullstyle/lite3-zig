/**
 * bench_raw.c - the same benchmark loops as src/bench.zig, written directly
 * against lite3's C API, so the wrapper's overhead can be measured.
 * Each function returns a negative value on failure.
 */
#include "lite3.h"
#include <stdint.h>
#include <stddef.h>

int64_t raw_set_i64(unsigned char *buf, size_t bufsz, uint64_t n)
{
    size_t len;
    if (lite3_init_obj(buf, &len, bufsz) < 0) return -1;
    for (uint64_t i = 0; i < n; i++)
        if (lite3_set_i64(buf, &len, 0, bufsz, "key", 42) < 0) return -1;
    return (int64_t)len;
}

int64_t raw_get_i64(const unsigned char *buf, size_t len, uint64_t n)
{
    int64_t sum = 0;
    for (uint64_t i = 0; i < n; i++) {
        int64_t v;
        if (lite3_get_i64(buf, len, 0, "key", &v) < 0) return -1;
        sum += v;
    }
    return sum;
}

int64_t raw_set_str(unsigned char *buf, size_t bufsz, uint64_t n)
{
    size_t len;
    if (lite3_init_obj(buf, &len, bufsz) < 0) return -1;
    for (uint64_t i = 0; i < n; i++)
        if (lite3_set_str(buf, &len, 0, bufsz, "key", "hello world benchmark string") < 0) return -1;
    return (int64_t)len;
}

int64_t raw_get_str(const unsigned char *buf, size_t len, uint64_t n)
{
    int64_t sum = 0;
    for (uint64_t i = 0; i < n; i++) {
        lite3_str s;
        if (lite3_get_str(buf, len, 0, "key", &s) < 0) return -1;
        sum += s.len;
    }
    return sum;
}

int64_t raw_append_i64(unsigned char *buf, size_t bufsz, uint64_t n)
{
    size_t len;
    if (lite3_init_arr(buf, &len, bufsz) < 0) return -1;
    for (uint64_t i = 0; i < n; i++)
        if (lite3_arr_append_i64(buf, &len, 0, bufsz, (int64_t)i) < 0) return -1;
    return (int64_t)len;
}

int64_t raw_iterate(const unsigned char *buf, size_t len)
{
    lite3_iter it;
    if (lite3_iter_create(buf, len, 0, &it) < 0) return -1;
    int64_t sum = 0;
    size_t val_ofs;
    int ret;
    while ((ret = lite3_iter_next(buf, len, &it, NULL, &val_ofs)) == LITE3_ITER_ITEM) {
        int64_t v;
        const lite3_val *val = (const lite3_val *)(buf + val_ofs);
        if (val->type != LITE3_TYPE_I64) return -1;
        __builtin_memcpy(&v, val->val, sizeof v);
        sum += v;
    }
    return ret < 0 ? -1 : sum;
}
