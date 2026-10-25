#include <inttypes.h>
#include <stdio.h>

#include "aimage_reader_usage.h"

/* BLASTBufferQueue's consumer usage, what a SurfaceView gives a decoder. */
#define SURFACE_VIEW_USAGE \
    (AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY)

int main(void)
{
    static const struct
    {
        const char *name;
        bool need_gpu;
        uint64_t want;
    } cases[] = {
        { "presented through SurfaceControl", false, SURFACE_VIEW_USAGE },
        { "sampled by VLC's OpenGL display", true, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE },
    };

    int failures = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
    {
        uint64_t got = AImageReaderUsage(cases[i].need_gpu);
        int ok = got == cases[i].want;
        printf("%-4s %s: usage %#" PRIx64 ", want %#" PRIx64 "\n",
               ok ? "ok" : "FAIL", cases[i].name, got, cases[i].want);
        failures += !ok;
    }
    return failures != 0;
}
