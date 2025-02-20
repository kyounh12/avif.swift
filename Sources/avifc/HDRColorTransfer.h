//
//  PerceptualQuantinizer.h
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

#ifndef PerceptualQuantinizer_h
#define PerceptualQuantinizer_h

#import "Color/Colorspace.h"

enum ColorGammaCorrection {
    Linear, Rec2020, DisplayP3, Rec709
};

enum TransferFunction {
    PQ, HLG, SMPTE428
};

@interface HDRColorTransfer : NSObject
+(void)transfer:(nonnull uint8_t*)data stride:(int)stride width:(int)width
         height:(int)height U16:(bool)U16 depth:(int)depth half:(bool)half
      primaries:(nonnull float*)primaries components:(int)components
gammaCorrection:(ColorGammaCorrection)gammaCorrection
       function:(TransferFunction)function
         matrix:(nullable ColorSpaceMatrix*)matrix
        profile:(nonnull ColorSpaceProfile*)profile;
@end

#endif /* PerceptualQuantinizer_h */
