#include "lite3.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int lite3_json_disabled_error(void) {
    errno = EINVAL;
    return -1;
}

int lite3_json_dec(unsigned char *buf, size_t *out_buflen, size_t bufsz, const char *json_str, size_t json_len) {
    (void)buf;
    (void)out_buflen;
    (void)bufsz;
    (void)json_str;
    (void)json_len;
    return lite3_json_disabled_error();
}

int lite3_json_dec_file(unsigned char *buf, size_t *out_buflen, size_t bufsz, const char *path) {
    (void)buf;
    (void)out_buflen;
    (void)bufsz;
    (void)path;
    return lite3_json_disabled_error();
}

int lite3_json_dec_fp(unsigned char *buf, size_t *out_buflen, size_t bufsz, FILE *fp) {
    (void)buf;
    (void)out_buflen;
    (void)bufsz;
    (void)fp;
    return lite3_json_disabled_error();
}

int lite3_json_print(const unsigned char *buf, size_t buflen, size_t ofs) {
    (void)buf;
    (void)buflen;
    (void)ofs;
    return lite3_json_disabled_error();
}

char *lite3_json_enc(const unsigned char *buf, size_t buflen, size_t ofs, size_t *out_len) {
    (void)buf;
    (void)buflen;
    (void)ofs;
    if (out_len) *out_len = 0;
    errno = EINVAL;
    return NULL;
}

char *lite3_json_enc_pretty(const unsigned char *buf, size_t buflen, size_t ofs, size_t *out_len) {
    (void)buf;
    (void)buflen;
    (void)ofs;
    if (out_len) *out_len = 0;
    errno = EINVAL;
    return NULL;
}

int64_t lite3_json_enc_buf(const unsigned char *buf, size_t buflen, size_t ofs, char *json_buf, size_t json_bufsz) {
    (void)buf;
    (void)buflen;
    (void)ofs;
    (void)json_buf;
    (void)json_bufsz;
    return lite3_json_disabled_error();
}

int64_t lite3_json_enc_pretty_buf(const unsigned char *buf, size_t buflen, size_t ofs, char *json_buf, size_t json_bufsz) {
    (void)buf;
    (void)buflen;
    (void)ofs;
    (void)json_buf;
    (void)json_bufsz;
    return lite3_json_disabled_error();
}
