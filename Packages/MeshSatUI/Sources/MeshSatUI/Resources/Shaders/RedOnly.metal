// Night mode: the red-only colour matrix of MeshSat Android's ui/theme/NightMode.kt.
// Colours arrive premultiplied, so the luminance is computed on the premultiplied channels
// and written back to red only; alpha is kept.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

[[ stitchable ]] half4 redOnly(float2 position, half4 color) {
    half l = 0.24h * color.r + 0.47h * color.g + 0.09h * color.b;
    return half4(l, 0.0h, 0.0h, color.a);
}
