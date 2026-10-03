/**
 * lite3_shim.c - C shim implementation (see lite3_shim.h for the conventions).
 */
#include "lite3.h"
#include "lite3_shim.h"
#include <errno.h>

static int status_from_errno(int e)
{
    switch (e) {
    case ENOENT: return LITE3ZIG_E_NOT_FOUND;
    case EINVAL: return LITE3ZIG_E_INVALID;
    case ENOBUFS:
    case EMSGSIZE: return LITE3ZIG_E_NO_SPACE;
    case EBADMSG:
    case EFAULT: return LITE3ZIG_E_CORRUPT;
    case ENOMEM: return LITE3ZIG_E_NO_MEMORY;
    case ENOSPC: return LITE3ZIG_E_KEY_COLLISION;
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

int shim_init(unsigned char *buf, size_t *out_buflen, size_t bufsz, uint8_t type)
{
    if (type == LITE3_TYPE_OBJECT) return st(lite3_init_obj(buf, out_buflen, bufsz));
    if (type == LITE3_TYPE_ARRAY) return st(lite3_init_arr(buf, out_buflen, bufsz));
    return -LITE3ZIG_E_INVALID;
}

int shim_insert(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz,
                const char *key, uint32_t hash, uint32_t key_size,
                uint8_t type, size_t payload_len, uint32_t *out_payload_ofs)
{
    int ret = st(_lite3_verify_set(buf, inout_buflen, ofs, bufsz));
    if (ret < 0) return ret;
    lite3_key_data key_data = { .hash = hash, .size = key_size };
    lite3_val *val;
    ret = st(lite3_set_impl(buf, inout_buflen, ofs, bufsz, key, key_data, payload_len, &val));
    if (ret < 0) return ret;
    val->type = type;
    *out_payload_ofs = (uint32_t)(val->val - buf);
    return 0;
}

int shim_insert_container(unsigned char *buf, size_t *inout_buflen, size_t ofs, size_t bufsz,
                          const char *key, uint32_t hash, uint32_t key_size,
                          uint8_t type, uint32_t *out_ofs)
{
    int ret = st(_lite3_verify_set(buf, inout_buflen, ofs, bufsz));
    if (ret < 0) return ret;
    size_t new_ofs = 0;
    if (key) {
        lite3_key_data key_data = { .hash = hash, .size = key_size };
        ret = type == LITE3_TYPE_OBJECT
            ? st(lite3_set_obj_impl(buf, inout_buflen, ofs, bufsz, key, key_data, &new_ofs))
            : st(lite3_set_arr_impl(buf, inout_buflen, ofs, bufsz, key, key_data, &new_ofs));
    } else {
        ret = type == LITE3_TYPE_OBJECT
            ? st(lite3_arr_set_obj_impl(buf, inout_buflen, ofs, bufsz, hash, &new_ofs))
            : st(lite3_arr_set_arr_impl(buf, inout_buflen, ofs, bufsz, hash, &new_ofs));
    }
    if (ret < 0) return ret;
    *out_ofs = (uint32_t)new_ofs;
    return 0;
}
