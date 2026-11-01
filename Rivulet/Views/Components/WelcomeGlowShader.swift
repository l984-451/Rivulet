// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

/// The welcome backdrop's shader: the icon's R, blurred, with its colors spilling
/// across the screen and one soft stream running down it. Compiled from source at
/// first use, so building the app needs no Metal toolchain. The maps come from
/// tools/welcome/flow_map.py; the look was tuned in a WebGL copy of this shader.
enum WelcomeGlowShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct WelcomeUniforms {
        float time;
        float2 flowScale;   // screen to R UV
        float2 flowCenter;  // R UV at the screen's centre
        float2 starScale;
        float starfield;
        float scrim;
    };

    struct WelcomeVertexOut {
        float4 position [[position]];
        float2 screen;
    };

    vertex WelcomeVertexOut welcomeVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        WelcomeVertexOut out;
        out.position = float4(p * 2 - 1, 0, 1);
        out.screen = float2(p.x, 1 - p.y);
        return out;
    }

    constant float3 palette[4] = {
        float3(0.30, 0.85, 0.95), float3(0.55, 0.42, 1.00),
        float3(1.00, 0.45, 0.72), float3(1.00, 0.78, 0.42),
    };

    static float3 flowColor(float p) {
        p = fract(p) * 4;
        int i = int(p);
        return mix(palette[i], palette[(i + 1) % 4], smoothstep(0.0, 1.0, fract(p)));
    }

    // Tuned values.
    constant float tripSeconds = 7, streamLength = 0.19, streamGain = 0.65;
    constant float drift = 0.085, bands = 0.75, bodyGain = 0.2, blur = 0.9;
    constant float halo = 0.9, haloSpread = 1.1, spill = 0.35, ripple = 0.006;
    constant float wash = 0.14;
    constant float2 scrimCenter = float2(0.5, 0.62);

    fragment float4 welcomeFragment(WelcomeVertexOut in [[stage_in]],
                                    constant WelcomeUniforms &u [[buffer(0)]],
                                    texture2d<float> flow [[texture(0)]],
                                    texture2d<float> spillMap [[texture(1)]],
                                    texture2d<float> stars [[texture(2)]]) {
        constexpr sampler edge(filter::linear, address::clamp_to_edge);
        constexpr sampler wrap(filter::linear, address::repeat);

        float2 uv = (in.screen - 0.5) * u.flowScale + u.flowCenter;
        uv += ripple * float2(sin(uv.y * 7 + u.time * 0.45), sin(uv.x * 6 - u.time * 0.35));
        // The maps hold the R in the middle half of a canvas twice its size.
        float2 c = (uv + 0.5) * 0.5;

        float4 t = flow.sample(edge, c);
        float phase = (t.r * 255 + t.b) / 256;
        float body = 0, near = 0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                body += flow.sample(edge, c + float2(x, y) * float2(0.002, 0.0033) * blur).g;
                near += flow.sample(edge, c + float2(x, y) * float2(0.009, 0.015) * haloSpread).g;
            }
        }
        body /= 25;
        near /= 25;
        float4 spillSample = spillMap.sample(edge, c);
    float wide = spillSample.r;

        // At rest: the palette along the R, drifting. One soft swell runs down it.
        float3 rest = flowColor(phase * bands - u.time * drift);
        float head = fract(u.time / tripSeconds) * (1 + streamLength * 2) - streamLength;
        float behind = head - phase;
        float width = streamLength * (behind >= 0 ? 0.6 : 0.3);
        float stream = exp(-behind * behind / (width * width));
        float3 streamColor = mix(flowColor(head * 1.1 + 0.15), float3(1), 0.1);

        float lit = body * bodyGain + near * halo + wide * spill;
        float3 color = rest * lit + streamColor * stream * (body * streamGain + near * halo * 0.35 + wide * spill * 0.3);
        // A wash of the R's colors across the whole view.
    color += flowColor(spillSample.b * bands - u.time * drift) * spillSample.g * wash;
    // Highlights roll off instead of clipping to white.
    color = min(color, 0.75) + 0.25 * (1 - exp(-max(color - 0.75, 0.0) / 0.25));
    float3 sky = stars.sample(wrap, (in.screen - 0.5) * u.starScale + 0.5).rgb * u.starfield;

        float2 q = (in.screen - scrimCenter) * float2(1.6, 4.5);
        return float4((sky + color) * (1 - u.scrim * exp(-dot(q, q))), 1);
    }
    """
}
