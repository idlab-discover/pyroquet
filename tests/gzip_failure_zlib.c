/* Fake codec dependency used only by subprocess failure tests. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static unsigned initialized, ended, active;
static int mode(const char *name) {
    const char *value = getenv("PYROQUET_TEST_ZLIB_FAILURE");
    return value && strcmp(value, name) == 0;
}
__attribute__((destructor)) static void audit(void) {
    const char *path = getenv("PYROQUET_TEST_ZLIB_AUDIT");
    if (!path) return;
    FILE *file = fopen(path, "w");
    if (!file) abort();
    fprintf(file, "%u %u %u\n", initialized, ended, active);
    fclose(file);
}
const char *zlibVersion(void) { return ZLIB_VERSION; }
uLong zlibCompileFlags(void) {
    return mode("abi") ? 0 : mode("winapi") ? 169 | (1UL << 10) :
        mode("no-gzip") ? 169 | (1UL << 17) : 169;
}
static int initialize(z_streamp stream) {
    if (mode("init-memory")) return Z_MEM_ERROR;
    stream->state = (struct internal_state *)malloc(1);
    if (!stream->state) return Z_MEM_ERROR;
    initialized++; active++;
    return Z_OK;
}
int inflateInit2_(z_streamp stream, int window, const char *version, int size) {
    (void)window; (void)version; (void)size;
    return initialize(stream);
}
int deflateInit2_(z_streamp stream, int level, int method, int window,
                  int memory, int strategy, const char *version, int size) {
    (void)level; (void)method; (void)window; (void)memory; (void)strategy;
    (void)version; (void)size;
    return initialize(stream);
}
static int finalize(z_streamp stream) {
    if (!stream->state || active == 0) abort();
    free(stream->state); stream->state = NULL;
    ended++; active--;
    return mode("end") ? Z_STREAM_ERROR : Z_OK;
}
int inflateEnd(z_streamp stream) { return finalize(stream); }
int deflateEnd(z_streamp stream) { return finalize(stream); }
int inflateReset2(z_streamp stream, int window) {
    (void)stream; (void)window;
    return Z_MEM_ERROR;
}
int inflate(z_streamp stream, int flush) {
    (void)flush;
    if (mode("stream-memory")) return Z_MEM_ERROR;
    if (mode("no-progress")) return Z_OK;
    if (mode("reset")) return Z_STREAM_END;
    if (mode("end")) {
        memset(stream->next_out, 0, stream->avail_out);
        stream->avail_out = 0;
        stream->avail_in = 0;
        return Z_STREAM_END;
    }
    return Z_DATA_ERROR;
}
uLong deflateBound(z_streamp stream, uLong length) {
    (void)stream;
    return mode("bound") ? ~0UL : length + 64;
}
int deflate(z_streamp stream, int flush) {
    (void)flush;
    if (mode("stream-memory")) return Z_MEM_ERROR;
    if (mode("no-progress")) return Z_OK;
    if (mode("end")) {
        stream->avail_in = 0;
        return Z_STREAM_END;
    }
    return Z_DATA_ERROR;
}
