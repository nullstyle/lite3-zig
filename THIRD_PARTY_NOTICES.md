# Third-party notices

lite3-zig is MIT-licensed (see `LICENSE`). It includes the following
third-party code, under `vendor/lite3/`:

| Component | Version | License | License file |
|---|---|---|---|
| [lite3](https://github.com/fastserial/lite3) | commit in `vendor/lite3/UPSTREAM`, with `vendor/patches/` applied | MIT | `vendor/lite3/LICENSE` |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 (as vendored by lite3) | MIT | `vendor/lite3/lib/yyjson/LICENSE` |
| [NibbleAndAHalf base64](https://github.com/superwills/NibbleAndAHalf) | 1.0.1 (as vendored by lite3) | zlib-style | `vendor/lite3/lib/nibble_base64/LICENSE` |

yyjson and base64 are compiled only when JSON decoding is enabled (the
default; `-Djson=false` leaves them out).
