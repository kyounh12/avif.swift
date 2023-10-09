//
//  PerceptualQuantinizer.mm
//  avif.swift [https://github.com/awxkee/avif.swift]
//
//  Created by Radzivon Bartoshyk on 06/09/2022.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

// https://review.mlplatform.org/plugins/gitiles/ml/ComputeLibrary/+/6ff3b19ee6120edf015fad8caab2991faa3070af/arm_compute/core/NEON/NEMath.inl
// https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-2019-PDF-E.pdf
// https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-2-201807-I!!PDF-E.pdf
// https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-2019-PDF-E.pdf

#import <Foundation/Foundation.h>
#import "PerceptualQuantinizer.h"
#import "Accelerate/Accelerate.h"

#if __has_include(<Metal/Metal.h>)
#import <Metal/Metal.h>
#endif
#import "TargetConditionals.h"

#ifdef __arm64__
#include <arm_neon.h>
#endif

#import "NEMath.h"

#import "Colorspace.h"
#import "ToneMap/Rec2408ToneMapper.hpp"
#import "half.hpp"

using namespace std;
using namespace half_float;

float sdrReferencePoint = 203.0f;

inline float ToLinearPQ(float v) {
    float o = v;
    v = max(0.0f, v);
    float m1 = (2610.0f / 4096.0f) / 4.0f;
    float m2 = (2523.0f / 4096.0f) * 128.0f;
    float c1 = 3424.0f / 4096.0f;
    float c2 = (2413.0f / 4096.0f) * 32.0f;
    float c3 = (2392.0f / 4096.0f) * 32.0f;
    float p = pow(v, 1.0f / m2);
    v = powf(max(p - c1, 0.0f) / (c2 - c3 * p), 1.0f / m1);
    v *= 10000.0f / sdrReferencePoint;
    return copysign(v, o);
}

struct TriStim {
    float r;
    float g;
    float b;
};

TriStim ClipToWhite(TriStim* c);

inline float Luma(TriStim &stim, const float* primaries) {
    return stim.r * primaries[0] + stim.g * primaries[1] + stim.b * primaries[2];
}

inline TriStim ClipToWhite(TriStim* c, const float* primaries) {
    float maximum = max(max(c->r, c->g), c->b);
    if (maximum > 1.0f) {
        float l = Luma(*c, primaries);
        c->r *= 1.0f / maximum;
        c->g *= 1.0f / maximum;
        c->b *= 1.0f / maximum;
        TriStim white = { 1.0f, 1.0f, 1.0f };
        float wScale = (1.0f - 1.0f / maximum) * l / Luma(white, primaries);
        white = { 1.0f*wScale, 1.0f*wScale, 1.0f*wScale };
        TriStim black = {0.0f, 0.0f, 0.0f };
        c->r += white.r;
        c->g += white.g;
        c->b += white.b;
    }
    return *c;
}

float clampf(float value, float min, float max) {
    return fmin(fmax(value, min), max);
}

void ToneMap(TriStim& stim, float luma, float* primaries) {
    if (luma < 1.0f) {
        return;
    }

    const float contentMaxLuma = 1.0f;
}

const auto sourceColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
const auto destinationColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
const auto info = CGColorConversionInfoCreate(sourceColorSpace, destinationColorSpace);

float SDRLuma(const float L, const float Lc, const float Ld) {
    float a = (Ld / Lc*Lc);
    float b = (1.0f / Ld);
    return L * (1 + a*L) / (1 + b*L);
}

inline half loadHalf(uint16_t t) {
    half f;
    f.data_ = t;
    return f;
}

void TransferROW_U16HFloats(uint16_t *data, PQGammaCorrection gammaCorrection, const float* primaries, ToneMapper* toneMapper) {
    auto r = (float) loadHalf(data[0]);
    auto g = (float) loadHalf(data[1]);
    auto b = (float) loadHalf(data[2]);
    TriStim smpte = {ToLinearPQ(r), ToLinearPQ(g), ToLinearPQ(b)};

    r = smpte.r;
    g = smpte.g;
    b = smpte.b;

    toneMapper->Execute(r, g, b);

    if (gammaCorrection == Rec2020) {
        data[0] = half(clamp(LinearRec2020ToRec2020(r), 0.0f, 1.0f)).data_;
        data[1] = half(clamp(LinearRec2020ToRec2020(g), 0.0f, 1.0f)).data_;
        data[2] = half(clamp(LinearRec2020ToRec2020(b), 0.0f, 1.0f)).data_;
    } else if (gammaCorrection == DisplayP3) {
        data[0] = half(clamp(LinearSRGBToSRGB(r), 0.0f, 1.0f)).data_;
        data[1] = half(clamp(LinearSRGBToSRGB(g), 0.0f, 1.0f)).data_;
        data[2] = half(clamp(LinearSRGBToSRGB(b), 0.0f, 1.0f)).data_;
    } else {
        data[0] = half(clamp(r, 0.0f, 1.0f)).data_;
        data[1] = half(clamp(g, 0.0f, 1.0f)).data_;
        data[2] = half(clamp(b, 0.0f, 1.0f)).data_;
    }
}

#if __arm64__

// Constants
const static float32x4_t zeros = vdupq_n_f32(0);
const static float m1 = (2610.0f / 4096.0f) / 4.0f;
const static float m2 = (2523.0f / 4096.0f) * 128.0f;
const static float32x4_t c1 = vdupq_n_f32(3424.0f / 4096.0f);
const static float32x4_t c2 = vdupq_n_f32((2413.0f / 4096.0f) * 32.0f);
const static float32x4_t c3 = vdupq_n_f32((2392.0f / 4096.0f) * 32.0f);
const static float m2Power = 1.0f / m2;
const static float m1Power = 1.0f / m1;

const static float lumaScale = 10000.0f / sdrReferencePoint;

__attribute__((always_inline))
inline float32x4_t ToLinearPQ(const float32x4_t v) {
    const float32x4_t rv = vmaxq_f32(v, zeros);
    float32x4_t p = vpowq_f32(rv, m2Power);
    return vcopysignq_f32(vmulq_n_f32(vpowq_f32(vdivq_f32(vmaxq_f32(vsubq_f32(p, c1), zeros), vmlsq_f32(c2, c3, p)), m1Power),
                                      lumaScale), rv);
}

const static float32x4_t linearM = vdupq_n_f32(2.3f);
const static float32x4_t linearM1 = vdupq_n_f32(0.8f);
const static float32x4_t linearM2 = vdupq_n_f32(0.2f);

__attribute__((always_inline))
inline float32x4_t dcpi3GammaCorrection(float32x4_t linear) {
    return vpowq_f32(linear, 1.0f/2.6f);
}

__attribute__((always_inline))
inline void SetPixelsRGB(float16x4_t rgb, uint16_t *vector, int components) {
    uint16x4_t t = vreinterpret_u16_f16(rgb);
    vst1_u16(vector, t);
}

__attribute__((always_inline))
inline void SetPixelsRGBU8(const float32x4_t rgb, uint8_t *vector, const float32x4_t maxColors) {
    const float32x4_t zeros = vdupq_n_f32(0);
    const float32x4_t v = vminq_f32(vmaxq_f32(vrndq_f32(vmulq_f32(rgb, maxColors)), zeros), maxColors);
}

__attribute__((always_inline))
inline float32x4_t GetPixelsRGBU8(const float32x4_t rgb, const float32x4_t maxColors) {
    const float32x4_t zeros = vdupq_n_f32(0);
    const float32x4_t v = vminq_f32(vmaxq_f32(vrndq_f32(vmulq_f32(rgb, maxColors)), zeros), maxColors);
    return v;
}

__attribute__((always_inline))
inline float32x4x4_t Transfer(float32x4_t rChan, float32x4_t gChan, 
                              float32x4_t bChan,
                              PQGammaCorrection gammaCorrection,
                              ToneMapper* toneMapper) {
    float32x4_t pqR = ToLinearPQ(rChan);
    float32x4_t pqG = ToLinearPQ(gChan);
    float32x4_t pqB = ToLinearPQ(bChan);

    float32x4x4_t m = {
        pqR, pqG, pqB, vdupq_n_f32(0.0f)
    };
    m = MatTransponseQF32(m);

    float32x4x4_t r = toneMapper->Execute(m);

    if (gammaCorrection == Rec2020) {
        r.val[0] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[0]), 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[1]), 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[2]), 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[3]), 0.0f, 1.0f);
    } else if (gammaCorrection == DisplayP3) {
        r.val[0] = vclampq_n_f32(LinearSRGBToSRGB(r.val[0]), 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(LinearSRGBToSRGB(r.val[1]), 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(LinearSRGBToSRGB(r.val[2]), 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(LinearSRGBToSRGB(r.val[3]), 0.0f, 1.0f);
    } else {
        r.val[0] = vclampq_n_f32(r.val[0], 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(r.val[1], 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(r.val[2], 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(r.val[3], 0.0f, 1.0f);
    }

    return r;
}

#endif

void TransferROW_U16(uint16_t *data, float maxColors, PQGammaCorrection gammaCorrection, float* primaries) {
//    auto r = (float) data[0];
//    auto g = (float) data[1]);
//    auto b = (float) data[2];
//    float luma = Luma(ToLinearToneMap(r), ToLinearToneMap(g), ToLinearToneMap(b), primaries);
//    TriStim smpte = {ToLinearPQ(r), ToLinearPQ(g), ToLinearPQ(b)};
//    float pqLuma = Luma(smpte, primaries);
//    float scale = luma / pqLuma;
//    data[0] = float_to_half((float) smpte.r * scale);
//    data[1] = float_to_half((float) smpte.g * scale);
//    data[2] = float_to_half((float) smpte.b * scale);
}

void TransferROW_U8(uint8_t *data, float maxColors, PQGammaCorrection gammaCorrection, ToneMapper* toneMapper) {
    auto r = (float) data[0] / (float) maxColors;
    auto g = (float) data[1] / (float) maxColors;
    auto b = (float) data[2] / (float) maxColors;
    TriStim smpte = {ToLinearPQ(r), ToLinearPQ(g), ToLinearPQ(b)};

    r = smpte.r;
    g = smpte.g;
    b = smpte.b;

    toneMapper->Execute(r, g, b);

    if (gammaCorrection == Rec2020) {
        r = LinearRec2020ToRec2020(r);
        g = LinearRec2020ToRec2020(g);
        b = LinearRec2020ToRec2020(b);
    } else if (gammaCorrection == DisplayP3) {
        r = LinearSRGBToSRGB(r);
        g = LinearSRGBToSRGB(g);
        b = LinearSRGBToSRGB(b);
    }

    data[0] = (uint8_t) clamp((float) round(r * maxColors), 0.0f, maxColors);
    data[1] = (uint8_t) clamp((float) round(g * maxColors), 0.0f, maxColors);
    data[2] = (uint8_t) clamp((float) round(b * maxColors), 0.0f, maxColors);
}

@implementation PerceptualQuantinizer : NSObject

#if __arm64__

+(void)transferNEONF16:(nonnull uint8_t*)data stride:(int)stride width:(int)width height:(int)height depth:(int)depth primaries:(float*)primaries
                 space:(PQGammaCorrection)space components:(int)components toneMapper:(ToneMapper*)toneMapper {
    auto ptr = reinterpret_cast<uint8_t *>(data);

    dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_apply(height, concurrentQueue, ^(size_t y) {

        auto ptr16 = reinterpret_cast<uint16_t *>(ptr + y * stride);
        int x;
        for (x = 0; x + 8 < width; x += 8) {
            if (components == 4) {
                float16x8x4_t rgbVector = vld4q_f16(reinterpret_cast<const float16_t *>(ptr16));

                float32x4_t rChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[0]));
                float32x4_t rChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[0]));
                float32x4_t gChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[1]));
                float32x4_t gChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[1]));
                float32x4_t bChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[2]));
                float32x4_t bChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[2]));
                float16x8_t aChannels = rgbVector.val[3];

                float32x4x4_t low = Transfer(rChannelsLow, gChannelsLow, bChannelsLow, space, toneMapper);

                low = MatTransponseQF32(low);

                float16x4_t rw1 = vcvt_f16_f32(low.val[0]);
                float16x4_t rw2 = vcvt_f16_f32(low.val[1]);
                float16x4_t rw3 = vcvt_f16_f32(low.val[2]);

                float32x4x4_t high = Transfer(rChannelsHigh, gChannelsHigh, bChannelsHigh, space, toneMapper);
                high = MatTransponseQF32(high);
                float16x4_t rw12 = vcvt_f16_f32(high.val[0]);
                float16x4_t rw22 = vcvt_f16_f32(high.val[1]);
                float16x4_t rw32 = vcvt_f16_f32(high.val[2]);
                float16x8_t finalRow1 = vcombine_f16(rw1, rw12);
                float16x8_t finalRow2 = vcombine_f16(rw2, rw22);
                float16x8_t finalRow3 = vcombine_f16(rw3, rw32);

                float16x8x4_t rw = { finalRow1, finalRow2, finalRow3, aChannels };
                vst4q_f16(reinterpret_cast<float16_t*>(ptr16), rw);
            } else {
                float16x8x3_t rgbVector = vld3q_f16(reinterpret_cast<const float16_t *>(ptr16));

                float32x4_t rChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[0]));
                float32x4_t rChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[0]));
                float32x4_t gChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[1]));
                float32x4_t gChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[1]));
                float32x4_t bChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[2]));
                float32x4_t bChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[2]));

                float32x4x4_t low = Transfer(rChannelsLow, gChannelsLow, bChannelsLow, space, toneMapper);

                float32x4x4_t m = {
                    low.val[0], low.val[1], low.val[2], low.val[3]
                };
                m = MatTransponseQF32(m);

                float32x4x4_t high = Transfer(rChannelsHigh, gChannelsHigh, bChannelsHigh, space, toneMapper);

                float32x4x4_t highM = {
                    high.val[0], high.val[1], high.val[2], high.val[3]
                };
                highM = MatTransponseQF32(highM);

                float16x8_t mergedR = vcombine_f16(vcvt_f16_f32(m.val[0]), vcvt_f16_f32(highM.val[0]));
                float16x8_t mergedG = vcombine_f16(vcvt_f16_f32(m.val[1]), vcvt_f16_f32(highM.val[1]));
                float16x8_t mergedB = vcombine_f16(vcvt_f16_f32(m.val[2]), vcvt_f16_f32(highM.val[2]));
                float16x8x3_t merged = { mergedR, mergedG, mergedB };
                vst3q_f16(reinterpret_cast<float16_t*>(ptr16), merged);
            }

            ptr16 += components*8;
        }

        for (; x < width; ++x) {
            TransferROW_U16HFloats(ptr16, space, primaries, toneMapper);
            ptr16 += components;
        }
    });
}

+(void)transferNEONU8:(nonnull uint8_t*)data
               stride:(int)stride width:(int)width height:(int)height depth:(int)depth
            primaries:(float*)primaries space:(PQGammaCorrection)space components:(int)components
           toneMapper:(ToneMapper*)toneMapper {
    auto ptr = reinterpret_cast<uint8_t *>(data);

    const float32x4_t mask = {1.0f, 1.0f, 1.0f, 0.0};

    const auto maxColors = powf(2, (float) depth) - 1;
    const auto mColors = vdupq_n_f32(maxColors);

    const float colorScale = 1.0f / float((1 << depth) - 1);

    const float32x4_t vMaxColors = vdupq_n_f32(maxColors);

    dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_apply(height, concurrentQueue, ^(size_t y) {
        auto ptr16 = reinterpret_cast<uint8_t *>(ptr + y * stride);
        int x;
        int pixels = 16;
        for (x = 0; x + pixels < width; x += pixels) {
            if (components == 4) {
                uint8x16x4_t rgbChannels = vld4q_u8(ptr16);

                uint8x8_t rChannelsLow = vget_low_u8(rgbChannels.val[0]);
                uint8x8_t rChannelsHigh = vget_high_f16(rgbChannels.val[0]);
                uint8x8_t gChannelsLow = vget_low_u8(rgbChannels.val[1]);
                uint8x8_t gChannelsHigh = vget_high_f16(rgbChannels.val[1]);
                uint8x8_t bChannelsLow = vget_low_u8(rgbChannels.val[2]);
                uint8x8_t bChannelsHigh = vget_high_f16(rgbChannels.val[2]);

                uint16x8_t rLowU16 = vmovl_u8(rChannelsLow);
                uint16x8_t gLowU16 = vmovl_u8(gChannelsLow);
                uint16x8_t bLowU16 = vmovl_u8(bChannelsLow);
                uint16x8_t rHighU16 = vmovl_u8(rChannelsHigh);
                uint16x8_t gHighU16 = vmovl_u8(gChannelsHigh);
                uint16x8_t bHighU16 = vmovl_u8(bChannelsHigh);

                float32x4_t rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rLowU16))), colorScale);
                float32x4_t gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gLowU16))), colorScale);
                float32x4_t bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bLowU16))), colorScale);

                float32x4x4_t low = Transfer(rLow, gLow, bLow, space, toneMapper);
                float32x4_t rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                float32x4_t rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                float32x4_t rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                float32x4_t rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedLowLow = {
                    rw1, rw2, rw3, rw4
                };
                transposedLowLow = MatTransponseQF32(transposedLowLow);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rLowU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gLowU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bLowU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedLowHigh = {
                    rw1, rw2, rw3, rw4
                };
                transposedLowHigh = MatTransponseQF32(transposedLowHigh);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedHighLow = {
                    rw1, rw2, rw3, rw4
                };
                transposedHighLow = MatTransponseQF32(transposedHighLow);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedHighHigh = {
                    rw1, rw2, rw3, rw4
                };
                transposedHighHigh = MatTransponseQF32(transposedHighHigh);

                uint8x8_t row1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedLowLow.val[0])),
                                                            vqmovn_u32(vcvtq_u32_f32(transposedLowHigh.val[0]))));
                uint8x8_t row2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedHighLow.val[0])),
                                                            vqmovn_u32(vcvtq_u32_f32(transposedHighHigh.val[0]))));
                uint8x16_t rowR = vcombine_u8(row1u16, row2u16);

                row1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedLowLow.val[1])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedLowHigh.val[1]))));
                row2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedHighLow.val[1])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedHighHigh.val[1]))));
                uint8x16_t rowG = vcombine_u8(row1u16, row2u16);

                row1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedLowLow.val[2])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedLowHigh.val[2]))));
                row2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedHighLow.val[2])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedHighHigh.val[2]))));
                uint8x16_t rowB = vcombine_u8(row1u16, row2u16);
                uint8x16x4_t result = {rowR, rowG, rowB, rgbChannels.val[3]};
                vst4q_u8(ptr16, result);
            } else {
                uint8x16x3_t rgbChannels = vld3q_u8(ptr16);

                uint8x8_t rChannelsLow = vget_low_u8(rgbChannels.val[0]);
                uint8x8_t rChannelsHigh = vget_high_f16(rgbChannels.val[0]);
                uint8x8_t gChannelsLow = vget_low_u8(rgbChannels.val[1]);
                uint8x8_t gChannelsHigh = vget_high_f16(rgbChannels.val[1]);
                uint8x8_t bChannelsLow = vget_low_u8(rgbChannels.val[2]);
                uint8x8_t bChannelsHigh = vget_high_f16(rgbChannels.val[2]);

                uint16x8_t rLowU16 = vmovl_u8(rChannelsLow);
                uint16x8_t gLowU16 = vmovl_u8(gChannelsLow);
                uint16x8_t bLowU16 = vmovl_u8(bChannelsLow);
                uint16x8_t rHighU16 = vmovl_u8(rChannelsHigh);
                uint16x8_t gHighU16 = vmovl_u8(gChannelsHigh);
                uint16x8_t bHighU16 = vmovl_u8(bChannelsHigh);

                float32x4_t rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rLowU16))), colorScale);
                float32x4_t gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gLowU16))), colorScale);
                float32x4_t bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bLowU16))), colorScale);

                float32x4x4_t low = Transfer(rLow, gLow, bLow, space, toneMapper);
                float32x4_t rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                float32x4_t rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                float32x4_t rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                float32x4_t rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedLowLow = {
                    rw1, rw2, rw3, rw4
                };
                transposedLowLow = MatTransponseQF32(transposedLowLow);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rLowU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gLowU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bLowU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedLowHigh = {
                    rw1, rw2, rw3, rw4
                };
                transposedLowHigh = MatTransponseQF32(transposedLowHigh);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedHighLow = {
                    rw1, rw2, rw3, rw4
                };
                transposedHighLow = MatTransponseQF32(transposedHighLow);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);
                float32x4x4_t transposedHighHigh = {
                    rw1, rw2, rw3, rw4
                };
                transposedHighHigh = MatTransponseQF32(transposedHighHigh);

                uint8x8_t row1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedLowLow.val[0])),
                                                            vqmovn_u32(vcvtq_u32_f32(transposedLowHigh.val[0]))));
                uint8x8_t row2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedHighLow.val[0])),
                                                            vqmovn_u32(vcvtq_u32_f32(transposedHighHigh.val[0]))));
                uint8x16_t rowR = vcombine_u8(row1u16, row2u16);

                row1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedLowLow.val[1])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedLowHigh.val[1]))));
                row2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedHighLow.val[1])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedHighHigh.val[1]))));
                uint8x16_t rowG = vcombine_u8(row1u16, row2u16);

                row1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedLowLow.val[2])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedLowHigh.val[2]))));
                row2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(transposedHighLow.val[2])),
                                                  vqmovn_u32(vcvtq_u32_f32(transposedHighHigh.val[2]))));
                uint8x16_t rowB = vcombine_u8(row1u16, row2u16);
                uint8x16x3_t result = {rowR, rowG, rowB};
                vst3q_u8(ptr16, result);
            }

            ptr16 += components*pixels;
        }

        for (; x < width; ++x) {
            TransferROW_U8(ptr16, maxColors, space, toneMapper);
            ptr16 += components;
        }
    });
}
#endif

+(bool)transferMetal: (nonnull uint8_t*)data stride:(int)stride width:(int)width height:(int)height
                 U16:(bool)U16
               depth:(int)depth
                half:(bool)half {
    // Always unavailable on simulator, there is not reason to try
#if TARGET_OS_SIMULATOR
    return false;
#endif
#if __has_include(<Metal/Metal.h>)
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return false;
    }

    NSError *error = nil;
    NSBundle *bundle = [NSBundle bundleForClass:[PerceptualQuantinizer class]];

    id<MTLLibrary> library = [device newDefaultLibraryWithBundle:bundle error:&error];
    if (error) {
        return false;
    }

    auto functionName = @"SMPTE2084";
    if (U16 && !half) {
        functionName = @"SMPTE2084U16";
    } else if (!U16) {
        functionName = @"SMPTE2084U16";
    }

    id<MTLFunction> kernelFunction = [library newFunctionWithName:functionName];
    if (!kernelFunction) {
        return false;
    }

    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    if (error) {
        return false;
    }

    MTLComputePipelineDescriptor *pipelineDesc = [[MTLComputePipelineDescriptor alloc] init];
    pipelineDesc.computeFunction = kernelFunction;
    id<MTLComputePipelineState> pipelineState = [device newComputePipelineStateWithFunction:kernelFunction error:&error];
    if (error) {
        return false;
    }

    auto pixelFormat = MTLPixelFormatRGBA16Float;
    if (U16 && !half) {
        pixelFormat = MTLPixelFormatRGBA16Uint;
    } else if (!U16) {
        pixelFormat = MTLPixelFormatRGBA8Uint;
    }
    auto textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                width:width height:height mipmapped:false];
    [textureDescriptor setUsage:MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
    auto texture = [device newTextureWithDescriptor:textureDescriptor];
    if (!texture) {
        return false;
    }
    auto region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:stride];

    NSUInteger dataSize = 4 * width * height * (U16 ? sizeof(uint16_t) : sizeof(uint8_t));

    NSUInteger bufferSize = sizeof(int);
    id<MTLBuffer> depthBuffer = [device newBufferWithLength:bufferSize options:MTLResourceStorageModeShared];
    int* depthPointer = (int *)[depthBuffer contents];
    *depthPointer = depth;

    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
    [computeEncoder setComputePipelineState:pipelineState];
    [computeEncoder setTexture:texture atIndex:0];
    [computeEncoder setBuffer:depthBuffer offset:0 atIndex:0];

    MTLSize threadsPerThreadgroup = MTLSizeMake(8, 8, 1);
    MTLSize threadgroups = MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1);
    [computeEncoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerThreadgroup];
    [computeEncoder endEncoding];

    // Commit the command buffer
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    [texture getBytes:data bytesPerRow:stride bytesPerImage:dataSize fromRegion:region mipmapLevel:0 slice:0];
    return true;
#else
    return false;
#endif
}

+(void)transfer:(nonnull uint8_t*)data stride:(int)stride width:(int)width height:(int)height
            U16:(bool)U16 depth:(int)depth half:(bool)half primaries:(float*)primaries
     components:(int)components gammaCorrection:(PQGammaCorrection)gammaCorrection {
    auto ptr = reinterpret_cast<uint8_t *>(data);
    ToneMapper* toneMapper = new Rec2408ToneMapper(1000.0f, 1.0f, sdrReferencePoint);
#if __arm64__
    if (U16 && half) {
        [self transferNEONF16:reinterpret_cast<uint8_t*>(data) stride:stride width:width height:height
                        depth:depth primaries:primaries space:gammaCorrection components:components toneMapper:toneMapper];
        delete toneMapper;
        return;
    }
    if (!U16) {
        [self transferNEONU8:reinterpret_cast<uint8_t*>(data) stride:stride width:width height:height
                       depth:depth primaries:primaries space:gammaCorrection components:components toneMapper:toneMapper];
        delete toneMapper;
        return;
    }
#endif
    auto maxColors = powf(2, (float) depth) - 1;

    dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_apply(height, concurrentQueue, ^(size_t y) {
        if (U16) {
            auto ptr16 = reinterpret_cast<uint16_t *>(ptr + y * stride);
            for (int x = 0; x < width; ++x) {
                if (half) {
                    TransferROW_U16HFloats(ptr16, gammaCorrection, primaries, toneMapper);
                } else {
                    TransferROW_U16(ptr16, maxColors, gammaCorrection, primaries);
                }
                ptr16 += components;
            }
        } else {
            auto ptr16 = reinterpret_cast<uint8_t *>(ptr + y * stride);
            for (int x = 0; x < width; ++x) {
                TransferROW_U8(ptr16, maxColors, gammaCorrection, toneMapper);
                ptr16 += components;
            }
        }
    });

    delete toneMapper;
}
@end
