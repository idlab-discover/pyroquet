/* Development-only audit of the C ABI used by Mojo's GZIP adapter. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <zlib.h>

#define FIELD(name, offset) _Static_assert(offsetof(z_stream, name) == offset, #name)
_Static_assert(sizeof(int) == 4 && sizeof(uInt) == 4, "32-bit C int required");
_Static_assert(sizeof(uLong) == 8 && sizeof(void *) == 8, "LP64 ABI required");
_Static_assert(sizeof(z_stream) == 112 && _Alignof(z_stream) == 8, "z_stream ABI");
FIELD(next_in, 0); FIELD(avail_in, 8); FIELD(total_in, 16);
FIELD(next_out, 24); FIELD(avail_out, 32); FIELD(total_out, 40);
FIELD(msg, 48); FIELD(state, 56); FIELD(zalloc, 64); FIELD(zfree, 72);
FIELD(opaque, 80); FIELD(data_type, 88); FIELD(adler, 96); FIELD(reserved, 104);

int main(void) {
    void *handle = dlopen("libz.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    const char *symbols[] = {"zlibVersion", "zlibCompileFlags", "inflateInit2_",
        "inflate", "inflateReset", "inflateEnd", "deflateInit2_", "deflate",
        "deflateBound", "deflateEnd"};
    for (unsigned i = 0; i < sizeof(symbols) / sizeof(symbols[0]); ++i) {
        if (!dlsym(handle, symbols[i])) {
            fprintf(stderr, "missing symbol: %s\n", symbols[i]);
            dlclose(handle); return 1;
        }
    }
    const char *(*version)(void) = dlsym(handle, "zlibVersion");
    unsigned long (*flags)(void) = dlsym(handle, "zlibCompileFlags");
    int (*init)(z_streamp, int, const char *, int) = dlsym(handle, "inflateInit2_");
    int (*end)(z_streamp) = dlsym(handle, "inflateEnd");
    /* Size flags: uint=32, ulong=64, pointer=64; default C calling convention. */
    if ((flags() & 63) != 41 || (flags() & (1UL << 10))) {
        fprintf(stderr, "incompatible runtime ABI flags: %lu\n", flags());
        dlclose(handle); return 1;
    }
    z_stream stream = {0};
    int status = init(&stream, 31, ZLIB_VERSION, sizeof(stream));
    if (status != Z_OK) { fprintf(stderr, "inflateInit2_: %d\n", status); dlclose(handle); return 1; }
    if (end(&stream) != Z_OK) { dlclose(handle); return 1; }
    Dl_info info;
    if (!dladdr((void *)version, &info)) { dlclose(handle); return 1; }
    printf("header=%s\nruntime=%s\nlibrary=%s\nflags=%lu\nstream_size=%zu\nstream_alignment=%zu\n",
        ZLIB_VERSION, version(), info.dli_fname, flags(), sizeof(stream), _Alignof(z_stream));
    dlclose(handle);
    return 0;
}
