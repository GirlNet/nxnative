// Compare the production upload shader with bcdec, including the Metal 4 argument-table path.
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../tex/nvn_bcdec.h"
#include "../tex/nvn_bcd_msl.h"

static uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static uint32_t random_word(uint32_t *s) { *s ^= *s << 13; *s ^= *s >> 17; *s ^= *s << 5; return *s; }
static void bits(uint8_t *b, unsigned pos, unsigned count, unsigned value) {
    for (unsigned i = 0; i < count; ++i) {
        unsigned at = pos + i;
        b[at / 8] = (b[at / 8] & ~(1u << (at % 8))) | (((value >> i) & 1u) << (at % 8));
    }
}
static void fill_blocks(uint8_t *data, size_t pitch, unsigned bw, unsigned bh, uint32_t seed) {
    for (unsigned y = 0; y < bh; ++y) for (unsigned x = 0; x < bw; ++x) {
        unsigned n = y * bw + x, mode = n % 9, variant = n / 9;
        uint8_t *b = data + y * pitch + x * 16;
        for (unsigned i = 0; i < 16; ++i) b[i] = (uint8_t)random_word(&seed);
        b[0] = mode == 8 ? 0 : (b[0] & ~((1u << (mode + 1)) - 1u)) | (1u << mode);
        if (mode == 0 || mode == 1 || mode == 2 || mode == 3 || mode == 7)
            bits(b, mode + 1, mode == 0 ? 4 : 6, variant % 64);
        if (mode == 4 || mode == 5) bits(b, mode + 1, 2, variant % 4);
        if (mode == 4) bits(b, 7, 1, (variant / 4) % 2);
    }
}

static int run_case(id<MTLDevice> dev, id<MTLComputePipelineState> ps, unsigned w, unsigned h, int srgb, int metal4) {
    unsigned bw = (w + 3) / 4, bh = (h + 3) / 4;
    size_t source_off = 256, pitch = (size_t)bw * 16 + 32, size = pitch * bh;
    size_t row = ((size_t)w * 4 + 255) & ~255ull, output_size = row * h;
    id<MTLBuffer> src = [dev newBufferWithLength:source_off + size options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:output_size options:MTLResourceStorageModeShared];
    id<MTLBuffer> params = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    uint8_t *expected = calloc(1, output_size);
    if (!src || !out || !params || !expected) abort();
    memset(src.contents, 0xCD, src.length); memset(out.contents, 0xCD, out.length);
    fill_blocks((uint8_t *)src.contents + source_off, pitch, bw, bh, 0x12345678);
    uint64_t start = now_ns();
    if (nvn_bc_decode(srgb ? 0x4E : 0x4D, (uint8_t *)src.contents + source_off, pitch, w, h, expected, row)) abort();
    double cpu_ms = (now_ns() - start) / 1e6;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm
                                                                                 width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    id<MTLTexture> view = srgb ? [texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm] : texture;
    if (!texture || !view) abort();
    uint32_t p[] = {(uint32_t)source_off, (uint32_t)pitch, w, h, 8};
    memcpy((uint8_t *)params.contents + 64, p, sizeof p);
    double gpu_ms = 0;
    if (metal4) {
        NSError *error = nil;
        id<MTL4CommandQueue> queue = [dev newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&error];
        id<MTL4CommandAllocator> alloc = [dev newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&error];
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2; ad.maxTextureBindCount = 1;
        id<MTL4ArgumentTable> table = [dev newArgumentTableWithDescriptor:ad error:&error];
        id<MTLResidencySet> residency = [dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
        if (!queue || !alloc || !table || !residency) { fprintf(stderr, "%s\n", error.description.UTF8String); free(expected); return 1; }
        id<MTLAllocation> resources[] = {src, out, params, texture};
        [residency addAllocations:resources count:4]; [residency commit]; [queue addResidencySet:residency];
        id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:alloc];
        id<MTL4ComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [table setAddress:src.gpuAddress atIndex:0]; [table setAddress:params.gpuAddress + 64 atIndex:1]; [table setTexture:view.gpuResourceID atIndex:0];
        [enc setArgumentTable:table]; [enc setComputePipelineState:ps];
        [enc dispatchThreadgroups:MTLSizeMake((bw + 7) / 8, (bh + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [enc barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [enc copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                    toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:output_size];
        [enc endEncoding]; [cb endCommandBuffer];
        dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSError *failure; __block double elapsed;
        MTL4CommitOptions *options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            failure = feedback.error; elapsed = (feedback.GPUEndTime - feedback.GPUStartTime) * 1000; dispatch_semaphore_signal(done);
        }];
        // Metal 4 command buffers do not retain resources; keep every object until feedback completes.
        NSArray *keep = @[src, out, params, texture, view, cb, alloc, table, residency, queue];
        id<MTL4CommandBuffer> buffers[] = {cb}; [queue commit:buffers count:1 options:options];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30ull * NSEC_PER_SEC))) abort();
        if (failure) { fprintf(stderr, "%s\n", failure.description.UTF8String); free(expected); return 1; }
        gpu_ms = elapsed;
        [queue removeResidencySet:residency];
        (void)keep.count;
    } else {
        id<MTLCommandQueue> queue = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps]; [enc setBuffer:src offset:0 atIndex:0]; [enc setBuffer:params offset:64 atIndex:1]; [enc setTexture:view atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake((bw + 7) / 8, (bh + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [enc endEncoding];
        id<MTLBlitCommandEncoder> read = [cb blitCommandEncoder];
        [read copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                     toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:output_size];
        [read endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { fprintf(stderr, "%s\n", cb.error.description.UTF8String); free(expected); return 1; }
        gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
    }
    size_t bad = 0; const uint8_t *got = out.contents;
    for (unsigned y = 0; y < h; ++y) for (size_t x = 0; x < (size_t)w * 4; ++x) bad += got[y * row + x] != expected[y * row + x];
    printf("Metal%d BC7%s %ux%u: %zu mismatched bytes; CPU %.3f ms, GPU + readback %.3f ms\n", metal4 ? 4 : 3, srgb ? " sRGB" : "", w, h, bad, cpu_ms, gpu_ms);
    free(expected); return bad != 0;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "No Metal device\n"); return 1; }
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_bcd_msl) options:nil error:&error];
        id<MTLComputePipelineState> ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bcd"] error:&error] : nil;
        if (!ps) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
        unsigned cases[][2] = {{4, 4}, {7, 5}, {33, 17}, {1024, 1024}, {7232, 832}};
        int failed = 0;
        for (int metal4 = 0; metal4 <= 1; ++metal4) for (int srgb = 0; srgb <= 1; ++srgb)
            for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; ++i) @autoreleasepool {
                failed |= run_case(dev, ps, cases[i][0], cases[i][1], srgb, metal4);
            }
        return failed;
    }
}
