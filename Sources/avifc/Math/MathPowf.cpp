//
//  math_powf.cpp
//  avif.swift [https://github.com/awxkee/avif.swift]
//
//  Created by Radzivon Bartoshyk on 10/10/2023.
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

#include "MathPowf.hpp"
/*
Based on x ^ n = exp(n * log(x))

Test func : powf(x, n)
Test Range: (1,1) < (x, n) < (10, 10)
Peak Error:    ~0.0010%
RMS  Error: ~0.0002%
*/

#include "math.h"

#if defined(__clang__)
#pragma clang fp contract(fast) exceptions(ignore) reassociate(on)
#endif

const float __powf_rng[2] = {
    1.442695041f,
    0.693147180f
};

const float __powf_lut[16] = {
    -2.295614848256274,     //p0    log
    -2.470711633419806,     //p4
    -5.686926051100417,     //p2
    -0.165253547131978,     //p6
    +5.175912446351073,     //p1
    +0.844006986174912,     //p5
    +4.584458825456749,     //p3
    +0.014127821926000,        //p7
    0.9999999916728642,        //p0    exp
    0.04165989275009526,     //p4
    0.5000006143673624,     //p2
    0.0014122663401803872,     //p6
    1.000000059694879,         //p1
    0.008336936973260111,     //p5
    0.16666570253074878,     //p3
    0.00019578093328483123    //p7
};

float powf_c(float x, float n)
{
    float a, b, c, d, xx;
    int m;

    union {
        float   f;
        int     i;
    } r;

    //extract exponent
    r.f = x;
    m = (r.i >> 23);
    m = m - 127;
    r.i = r.i - (m << 23);

    //Taylor Polynomial (Estrins)
    xx = r.f * r.f;
    a = (__powf_lut[4] * r.f) + (__powf_lut[0]);
    b = (__powf_lut[6] * r.f) + (__powf_lut[2]);
    c = (__powf_lut[5] * r.f) + (__powf_lut[1]);
    d = (__powf_lut[7] * r.f) + (__powf_lut[3]);
    a = a + b * xx;
    c = c + d * xx;
    xx = xx * xx;
    r.f = a + c * xx;

    //add exponent
    r.f = r.f + ((float) m) * __powf_rng[1];

    r.f = r.f * n;

    //Range Reduction:
    m = (int) (r.f * __powf_rng[0]);
    r.f = r.f - ((float) m) * __powf_rng[1];

    //Taylor Polynomial (Estrins)
    a = (__powf_lut[12] * r.f) + (__powf_lut[8]);
    b = (__powf_lut[14] * r.f) + (__powf_lut[10]);
    c = (__powf_lut[13] * r.f) + (__powf_lut[9]);
    d = (__powf_lut[15] * r.f) + (__powf_lut[11]);
    xx = r.f * r.f;
    a = a + b * xx;
    c = c + d * xx;
    xx = xx* xx;
    r.f = a + c * xx;

    //multiply by 2 ^ m
    m = m << 23;
    r.i = r.i + m;

    return r.f;
}
