#include <stdint.h>

// Interleaves separate U and V planar buffers into NV12 UV plane.
// Uses __restrict to enable clang auto-vectorization (NEON on ARM64).
void uvInterleave(const uint8_t * __restrict srcU, int strideU,
                  const uint8_t * __restrict srcV, int strideV,
                  uint8_t       * __restrict dst,  int strideDst,
                  int width, int height) {
    for (int y = 0; y < height; y++) {
        const uint8_t *u = srcU + (int64_t)y * strideU;
        const uint8_t *v = srcV + (int64_t)y * strideV;
        uint8_t       *d = dst  + (int64_t)y * strideDst;
        for (int x = 0; x < width; x++) {
            d[2 * x]     = u[x];
            d[2 * x + 1] = v[x];
        }
    }
}
