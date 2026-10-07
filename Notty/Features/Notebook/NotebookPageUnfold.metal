/*
 * This file adapts the shader named below to one glass pane hinged along a newly added page's top edge.
 *
 * The fragment shader is a port of duo_unfold.agsl from Duo Open (github.com/marcoazeem/duo-open).
 *
 * MIT License
 *
 * Copyright (c) 2026 marcoazeem
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
 * documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of
 * the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 * WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

/*
 * Model: the new page lies on a fixed plane; the eye is on that plane's normal through the middle of the page's top
 * edge, eyeDistance back; one glass pane, the page, is tilted about that edge, its far edge toward the eye. Per pane
 * pixel: the ray from the eye through the glass point, continued to the page; a Vogel-disk blur, rotated per pixel,
 * whose radius grows with the glass-to-page gap; light lost in proportion to the blur; the dark the page is laid on
 * wherever the kernel misses the page.
 *
 * Each fragment finds the pane pixel the model shows at its own point of the page, so the page stays still and only
 * its frost changes: sharp along the top edge, deepening down the page, clearing from the top down as the pane lands.
 *
 * The model measures distance below the edge distanceScale times the page's, so the far edge lies the timeline's
 * extent below the hinge whatever the page's height; what it hits is sampled back at the page's own scale, and its
 * blur radius is in page points.
 */

#include <metal_stdlib>
using namespace metal;

/// Laid out as NotebookPageUnfold.Uniforms.
struct PageUnfoldUniforms {
    float4 glass;           // sRGB backdrop the page is added over, shown wherever the glass misses the page
    float2 size;            // the page, in points
    float2 pixelsPerPoint;  // drawable pixels per page point
    float tilt;             // degrees
    float eyeDistance;      // points
    float blurSpread;       // blur radius per point of gap
    float darkening;        // light lost per point of blur radius
    float maxTaps;
    float distanceScale;    // the model's distance below the hinge per page point
};

struct PageUnfoldVertex {
    float4 position [[position]];
};

constant float GOLDEN_ANGLE = 2.39996322972865332;
constant float TWO_PI = 6.28318530717958648;

/// One triangle that covers the drawable.
vertex PageUnfoldVertex pageUnfoldVertex(uint id [[vertex_id]]) {
    float2 corner = float2(float((id << 1) & 2), float(id & 2));
    return { float4(corner * 2.0 - 1.0, 0.0, 1.0) };
}

// GLSL's radians(), which Metal lacks.
static float radians(float degrees) {
    return degrees * (M_PI_F / 180.0);
}

// The page, or beyond its edges the backdrop, so a sample there adds that.
static float3 content(float2 p, constant PageUnfoldUniforms &u, texture2d<float> page, sampler paper) {
    if (p.x < 0.0 || p.y < 0.0 || p.x > u.size.x || p.y > u.size.y) return u.glass.rgb;
    return page.sample(paper, p / u.size).rgb;
}

// duo_unfold.agsl's main(), per pane pixel p, with the hinge along the page's top edge (y = 0). The original
// evaluates content() on its layer, which shows the glass colour beyond its bounds; its fixed 32-tap loop with a
// weight mask is a loop that stops at tapsF.
static float3 duo(float2 p, float2 fragCoord, constant PageUnfoldUniforms &u, texture2d<float> page, sampler paper) {
    float tilt = radians(clamp(u.tilt, 0.0, 60.0));
    if (tilt < 1e-4) return content(p, u, page, paper);

    float d = abs(p.y) * u.distanceScale;
    float2 glass = float2(p.x, d * cos(tilt));
    float gap = d * sin(tilt);
    float2 eye = float2(u.size.x * 0.5, 0.0);

    float depth = u.eyeDistance - gap;
    if (depth <= 1e-3) return u.glass.rgb;
    float2 hit = eye + (glass - eye) * (u.eyeDistance / depth);
    // Back on the page: the eye sits on the hinge, so only the distance below it was scaled.
    hit.y /= u.distanceScale;

    float radius = u.blurSpread * gap;
    if (hit.x < -radius || hit.y < -radius || hit.x > u.size.x + radius || hit.y > u.size.y + radius) {
        return u.glass.rgb;
    }

    float atten = max(1.0 - u.darkening * radius, 0.0);
    if (radius < 0.5) return content(hit, u, page, paper) * atten;

    float tapsF = clamp(radius * 2.0, 6.0, u.maxTaps);
    // The precise sine keeps the low digits this hash depends on at coordinates this large; the fast one bands it.
    float rotation = fract(precise::sin(dot(fragCoord, float2(12.9898, 78.233))) * 43758.5453) * TWO_PI;
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 32; i++) {
        float fi = float(i);
        if (fi >= tapsF) break;
        float r = radius * sqrt((fi + 0.5) / tapsF);
        float a = fi * GOLDEN_ANGLE + rotation;
        sum += content(hit + r * float2(cos(a), sin(a)), u, page, paper);
        wsum += 1.0;
    }
    return sum / max(wsum, 1.0) * atten;
}

// The pane pixel the page shows at its point x: the projection down the page, inverted, its distance below the hinge
// returned at the page's scale for duo() to scale again.
static float2 innerPane(float2 x, constant PageUnfoldUniforms &u) {
    float tilt = radians(clamp(u.tilt, 0.0, 60.0));
    float eye = u.eyeDistance;
    float v = x.y * u.distanceScale;
    float d = abs(v) * eye / (eye * cos(tilt) + abs(v) * sin(tilt));
    float across = u.size.x * 0.5 + (x.x - u.size.x * 0.5) * (eye - d * sin(tilt)) / eye;
    return float2(across, sign(v) * d / u.distanceScale);
}

fragment float4 pageUnfoldFragment(
    PageUnfoldVertex in [[stage_in]],
    constant PageUnfoldUniforms &u [[buffer(0)]],
    texture2d<float> page [[texture(0)]]
) {
    constexpr sampler paper(filter::linear, address::clamp_to_edge);
    // Metal's fragment origin is the top left, as the page's is.
    float2 fragCoord = in.position.xy;
    float2 x = fragCoord / u.pixelsPerPoint;
    return float4(duo(innerPane(x, u), fragCoord, u, page, paper), 1.0);
}
