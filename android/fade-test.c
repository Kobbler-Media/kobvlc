#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "fade.h"

#define RAMP 480
#define FRAMES 2048
#define CHANNELS 2

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: ", __func__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

static void FillFloat(float *buf, uint32_t frames)
{
    for (uint32_t i = 0; i < frames * CHANNELS; i++)
        buf[i] = (i % CHANNELS) ? -0.8f : 0.8f;
}

static void FillS16(int16_t *buf, uint32_t frames)
{
    for (uint32_t i = 0; i < frames * CHANNELS; i++)
        buf[i] = (i % CHANNELS) ? -30000 : 30000;
}

static void RisesFromSilenceThenPassesThrough(void)
{
    struct android_fade f;
    android_fade_In(&f, RAMP);

    float buf[FRAMES * CHANNELS];
    FillFloat(buf, FRAMES);
    android_fade_Apply(&f, buf, FRAMES, CHANNELS, true);

    CHECK(fabsf(buf[0]) <= 0.8f / RAMP + 1e-6f, "first frame too loud: %f", buf[0]);
    float prev = 0.f;
    for (uint32_t i = 0; i < FRAMES; i++)
    {
        float gain = buf[i * CHANNELS] / 0.8f;
        CHECK(fabsf(buf[i * CHANNELS + 1] + buf[i * CHANNELS]) < 1e-6f,
              "channels of frame %u got different gains", i);
        CHECK(gain >= prev - 1e-6f, "gain fell at frame %u", i);
        CHECK(gain - prev <= 1.f / RAMP + 1e-5f, "gain jumped at frame %u", i);
        if (i >= RAMP)
            CHECK(buf[i * CHANNELS] == 0.8f, "frame %u not at full level", i);
        prev = gain;
    }
}

static void LeavesSamplesAloneOnceIn(void)
{
    struct android_fade f;
    android_fade_In(&f, RAMP);

    float warmup[RAMP * CHANNELS];
    FillFloat(warmup, RAMP);
    android_fade_Apply(&f, warmup, RAMP, CHANNELS, true);

    float fl[FRAMES * CHANNELS], fl_ref[FRAMES * CHANNELS];
    FillFloat(fl, FRAMES);
    memcpy(fl_ref, fl, sizeof(fl));
    android_fade_Apply(&f, fl, FRAMES, CHANNELS, true);
    CHECK(memcmp(fl, fl_ref, sizeof(fl)) == 0, "float samples changed after the ramp");

    int16_t s[FRAMES * CHANNELS], s_ref[FRAMES * CHANNELS];
    FillS16(s, FRAMES);
    memcpy(s_ref, s, sizeof(s));
    android_fade_Apply(&f, s, FRAMES, CHANNELS, false);
    CHECK(memcmp(s, s_ref, sizeof(s)) == 0, "s16 samples changed after the ramp");
}

static void RampsS16(void)
{
    struct android_fade f;
    android_fade_In(&f, RAMP);

    int16_t buf[FRAMES * CHANNELS];
    FillS16(buf, FRAMES);
    android_fade_Apply(&f, buf, FRAMES, CHANNELS, false);

    CHECK(buf[0] < 30000 / RAMP + 1, "first frame too loud: %d", buf[0]);
    CHECK(buf[RAMP / 2 * CHANNELS] > 14000 && buf[RAMP / 2 * CHANNELS] < 16000,
          "halfway through the ramp at %d", buf[RAMP / 2 * CHANNELS]);
    CHECK(buf[RAMP * CHANNELS] == 30000 && buf[RAMP * CHANNELS + 1] == -30000,
          "not at full level after the ramp");
}

static void ChunkingDoesNotChangeTheRamp(void)
{
    static const uint32_t chunks[] = { 1, 7, 96, 192, 33 };
    struct android_fade whole, split;
    android_fade_In(&whole, RAMP);
    android_fade_In(&split, RAMP);

    float a[FRAMES * CHANNELS], b[FRAMES * CHANNELS];
    FillFloat(a, FRAMES);
    FillFloat(b, FRAMES);
    android_fade_Apply(&whole, a, FRAMES, CHANNELS, true);
    for (uint32_t done = 0, c = 0; done < FRAMES; c = (c + 1) % 5)
    {
        uint32_t n = chunks[c] < FRAMES - done ? chunks[c] : FRAMES - done;
        android_fade_Apply(&split, b + done * CHANNELS, n, CHANNELS, true);
        done += n;
    }
    CHECK(memcmp(a, b, sizeof(a)) == 0, "callback sizes changed the ramp");
}

static void RestartingGoesBackToSilence(void)
{
    struct android_fade f;
    android_fade_In(&f, RAMP);

    float buf[FRAMES * CHANNELS];
    FillFloat(buf, FRAMES);
    android_fade_Apply(&f, buf, FRAMES, CHANNELS, true);

    android_fade_In(&f, RAMP);
    FillFloat(buf, FRAMES);
    android_fade_Apply(&f, buf, FRAMES, CHANNELS, true);
    CHECK(fabsf(buf[0]) <= 0.8f / RAMP + 1e-6f, "restarted ramp began at %f", buf[0]);
}

int main(void)
{
    RisesFromSilenceThenPassesThrough();
    LeavesSamplesAloneOnceIn();
    RampsS16();
    ChunkingDoesNotChangeTheRamp();
    RestartingGoesBackToSilence();

    if (failures)
    {
        printf("fade-test: %d failures\n", failures);
        return 1;
    }
    printf("fade-test: ok\n");
    return 0;
}
