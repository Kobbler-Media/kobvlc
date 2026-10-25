#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "pacing.h"
#include "vsync_fit.h"

#define MS INT64_C(1000000)
#define SECONDS INT64_C(1000000000)
#define BAND_FRAMES 50

struct scenario
{
    const char *name;
    int64_t content_num, content_den;
    int timestamps_in_ms;
    int64_t panel_period;
    int64_t panel_wander;
    int64_t date_jitter;
    int64_t timeline_spacing;
    int64_t clock_drift_ppm;
};

static uint64_t rng = 88172645463325252u;

static int64_t Jitter(int64_t amplitude)
{
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    if (amplitude == 0)
        return 0;
    return (int64_t)(rng % (uint64_t)(2 * amplitude + 1)) - amplitude;
}

#define WANDER_PERIOD (40 * SECONDS)

struct panel
{
    int64_t origin, period, wander;
};

static int64_t Vsync(const struct panel *p, int64_t index)
{
    double cycles = (double)(index * p->period) / WANDER_PERIOD;
    return p->origin + index * p->period
         + (int64_t)(p->wander * sin(2 * M_PI * cycles));
}

static int64_t NextVsync(const struct panel *p, int64_t t)
{
    int64_t index = t <= p->origin ? 0 : (t - p->origin) / p->period;
    while (index > 0 && Vsync(p, index - 1) >= t)
        index--;
    while (Vsync(p, index) < t)
        index++;
    return index;
}

/* Frames presented off the cadence a jitter-free timeline would give: with the
 * ideal vsync position x of each frame, n - x has to stay inside one vsync wide
 * band; a frame outside the band its neighbours share was held or hurried. */
static int Misplaced(const double *x, const int64_t *n, int count)
{
    int misplaced = 0;
    double *r = malloc(sizeof(*r) * (2 * BAND_FRAMES + 1));
    for (int i = 0; i < count; i++)
    {
        int lo = i > BAND_FRAMES ? i - BAND_FRAMES : 0;
        int hi = i + BAND_FRAMES < count ? i + BAND_FRAMES + 1 : count;
        int len = 0;
        for (int k = lo; k < hi; k++)
        {
            double v = n[k] - x[k];
            int j = len++;
            while (j > 0 && r[j - 1] > v) { r[j] = r[j - 1]; j--; }
            r[j] = v;
        }
        int best = 0; double start = 0;
        for (int k = 0, j = 0; k < len; k++)
        {
            while (r[k] - r[j] >= 1 - 1e-9) j++;
            if (k - j + 1 > best) { best = k - j + 1; start = r[j]; }
        }
        double v = n[i] - x[i];
        if (v < start - 1e-9 || v >= start + 1 - 1e-9)
            misplaced++;
    }
    free(r);
    return misplaced;
}

static int Run(const struct scenario *s, int64_t duration, int64_t phase)
{
    struct android_pacing pacing;
    android_pacing_Init(&pacing);
    struct android_vsync_fit fit;
    android_vsync_fit_Init(&fit);

    const struct panel panel = {
        3 * SECONDS + 3100000, s->panel_period, s->panel_wander
    };
    const int64_t start = 4 * SECONDS + phase;
    int count = (int)(duration * s->content_num / s->content_den / SECONDS);
    double *x = malloc(sizeof(*x) * count);
    int64_t *n = malloc(sizeof(*n) * count);

    int64_t sample_time = 0, sample_period = 0, next_sample = 0;
    for (int i = 0; i < count; i++)
    {
        int64_t exact = (int64_t)i * s->content_den * SECONDS / s->content_num;
        int64_t pts = s->timestamps_in_ms ? exact / MS * MS : exact;
        int64_t date = start + exact + exact / 1000000 * s->clock_drift_ppm
                     + Jitter(s->date_jitter);
        int64_t now = date - 8 * MS;

        if (now >= next_sample)
        {
            int64_t vsync = Vsync(&panel, NextVsync(&panel, now));
            android_vsync_fit_Sample(&fit, vsync + Jitter(200000),
                                     s->timeline_spacing,
                                     &sample_time, &sample_period);
            next_sample = now + SECONDS / 2;
        }

        int64_t release = android_pacing_Adjust(&pacing, pts, date,
                                                sample_time, sample_period);
        n[i] = NextVsync(&panel, release);
        x[i] = (double)(start + exact + exact / 1000000 * s->clock_drift_ppm
                        - panel.origin) / s->panel_period;
    }

    int misplaced = Misplaced(x, n, count);
    double per_minute = misplaced * 60.0 * SECONDS / duration;
    printf("%-48s phase %5.2fms %5d frames, %4d misplaced (%.1f/min)\n",
           s->name, phase / 1e6, count, misplaced, per_minute);
    free(x);
    free(n);
    return per_minute <= 1.0;
}

int main(void)
{
    const int64_t pixel = 16580000, nominal60 = 16666667;
#define FPS(n, d) .content_num = n, .content_den = d
    const struct scenario scenarios[] = {
        { "25fps, panel at 60.3Hz, steady clock", FPS(25, 1),
          .panel_period = pixel, .timeline_spacing = pixel },
        { "25fps, panel at 60.3Hz, clock jitter", FPS(25, 1),
          .panel_period = pixel, .timeline_spacing = pixel,
          .date_jitter = 500000 },
        { "23.976 in ms, panel at 60.3Hz, clock jitter", FPS(24000, 1001),
          .timestamps_in_ms = 1, .panel_period = pixel,
          .timeline_spacing = pixel, .date_jitter = 500000 },
        { "25fps, timelines at the nominal 60Hz", FPS(25, 1),
          .panel_period = pixel, .timeline_spacing = nominal60,
          .date_jitter = 500000 },
        { "23.976 in ms, timelines at the nominal 60Hz", FPS(24000, 1001),
          .timestamps_in_ms = 1, .panel_period = pixel,
          .timeline_spacing = nominal60, .date_jitter = 500000 },
        { "23.976 in ms, 59.94Hz TV", FPS(24000, 1001),
          .timestamps_in_ms = 1, .panel_period = 16683350,
          .timeline_spacing = 16683350, .date_jitter = 500000 },
        { "24fps, clock drifting 50ppm", FPS(24, 1),
          .panel_period = pixel, .timeline_spacing = nominal60,
          .date_jitter = 500000, .clock_drift_ppm = 50 },
        { "25fps, panel wandering 3ms over 40s", FPS(25, 1),
          .panel_period = pixel, .panel_wander = 3000000,
          .timeline_spacing = nominal60, .date_jitter = 500000 },
    };

    int failed = 0;
    for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++)
        for (int64_t phase = 0; phase < 16 * MS; phase += 2 * MS)
            if (!Run(&scenarios[i], 300 * SECONDS, phase))
                failed++;
    if (failed)
        printf("%d run(s) above 1 misplaced frame a minute\n", failed);
    return failed != 0;
}
