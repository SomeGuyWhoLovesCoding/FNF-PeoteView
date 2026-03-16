package utils;

@:publicFields
class Shaders {
    static inline var UPSCALE_FRAGMENT_SHADER =
        '
        vec4 ravuSample(int textureID, vec2 uv, vec2 texelSize, vec2 lo, vec2 hi) {
    vec2 texPos  = uv / texelSize - 0.5;
    vec2 texPos1 = floor(texPos);
    vec2 phase   = texPos - texPos1;

    vec2 ph2 = phase * phase;
    vec2 ph3 = ph2  * phase;

    vec2 w0 = -0.5 * ph3 + 1.0 * ph2 - 0.5 * phase;
    vec2 w1 =  1.5 * ph3 - 2.5 * ph2 + 1.0;
    vec2 w2 = -1.5 * ph3 + 2.0 * ph2 + 0.5 * phase;
    vec2 w3 =  0.5 * ph3 - 0.5 * ph2;

    vec2 wA = w0 + w1;
    vec2 wB = w2 + w3;
    vec2 uvA = clamp((texPos1 + w1 / wA) * texelSize, lo, hi);
    vec2 uvB = clamp((texPos1 + 2.0 + w3 / wB) * texelSize, lo, hi);

    vec4 sAA = getTextureColor(textureID, vec2(uvA.x, uvA.y));
    vec4 sBA = getTextureColor(textureID, vec2(uvB.x, uvA.y));
    vec4 sAB = getTextureColor(textureID, vec2(uvA.x, uvB.y));
    vec4 sBB = getTextureColor(textureID, vec2(uvB.x, uvB.y));

    float hA = wA.x / (wA.x + wB.x);
    float hB = wA.y / (wA.y + wB.y);
    vec4 upscaled = mix(mix(sBB, sAB, hA), mix(sBA, sAA, hA), hB);

    // --- 8-neighborhood (axis + diagonal) ---
    vec4 nc  = getTextureColor(textureID, clamp(uv + vec2( 0.0,          -texelSize.y), lo, hi));
    vec4 sc  = getTextureColor(textureID, clamp(uv + vec2( 0.0,           texelSize.y), lo, hi));
    vec4 ec  = getTextureColor(textureID, clamp(uv + vec2( texelSize.x,   0.0        ), lo, hi));
    vec4 wc  = getTextureColor(textureID, clamp(uv + vec2(-texelSize.x,   0.0        ), lo, hi));
    vec4 ne  = getTextureColor(textureID, clamp(uv + vec2( texelSize.x,  -texelSize.y), lo, hi));
    vec4 nw  = getTextureColor(textureID, clamp(uv + vec2(-texelSize.x,  -texelSize.y), lo, hi));
    vec4 se  = getTextureColor(textureID, clamp(uv + vec2( texelSize.x,   texelSize.y), lo, hi));
    vec4 sw  = getTextureColor(textureID, clamp(uv + vec2(-texelSize.x,   texelSize.y), lo, hi));
    vec4 center = getTextureColor(textureID, uv);

    // Min/max clamp from full 8-neighborhood
    vec4 minN = min(center, min(min(nc, sc), min(ec, wc)));
    vec4 maxN = max(center, max(max(nc, sc), max(ec, wc)));
    minN = min(minN, min(min(ne, nw), min(se, sw)));
    maxN = max(maxN, max(max(ne, nw), max(se, sw)));

    // Laplacian sharpening (axis-only, same as before)
    vec4 lap = center * 4.0 - (nc + sc + ec + wc);

    // --- Seam suppression ---
    float edgeDist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float seamMask = smoothstep(0.0, texelSize.x * 2.0, edgeDist);

    upscaled.rgb = clamp(
        upscaled.rgb + lap.rgb * 0.8 * seamMask,
        minN.rgb, maxN.rgb
    );

    // --- Luminance for all 8 neighbors ---
    vec3  LUM  = vec3(0.299, 0.587, 0.114);
    float lumC  = dot(center.rgb, LUM);
    float lumN  = dot(nc.rgb,  LUM);
    float lumS  = dot(sc.rgb,  LUM);
    float lumE  = dot(ec.rgb,  LUM);
    float lumW  = dot(wc.rgb,  LUM);
    float lumNE = dot(ne.rgb,  LUM);
    float lumNW = dot(nw.rgb,  LUM);
    float lumSE = dot(se.rgb,  LUM);
    float lumSW = dot(sw.rgb,  LUM);

    // Sobel-style gradient magnitude ~ catches diagonals
    float gx = (lumNE + 2.0*lumE + lumSE) - (lumNW + 2.0*lumW + lumSW);
    float gy = (lumSW + 2.0*lumS + lumSE) - (lumNW + 2.0*lumN + lumNE);
    float gradMag = sqrt(gx*gx + gy*gy) / 4.0; // normalize to ~[0,1]

    // lapMag still used for sharpness guard
    float lapMag = length(lap.rgb) / 6.0;

    // aaSmooth: trigger on gradient, guard against flat areas with lapMag
    float aaSmooth = smoothstep(0.08, 0.4, gradMag) * smoothstep(0.04, 0.15, lapMag);

    // Determine dominant edge direction from Sobel gradient angle
    float absGx = abs(gx);
    float absGy = abs(gy);

    vec4 edgeBlend;

    if (absGx < absGy * 0.4) {
        // Near-horizontal edge ~ blend N/S
        edgeBlend = mix(upscaled, (upscaled + nc + sc) * (1.0/3.0), aaSmooth * 0.45);
    } else if (absGy < absGx * 0.4) {
        // Near-vertical edge ~ blend E/W
        edgeBlend = mix(upscaled, (upscaled + ec + wc) * (1.0/3.0), aaSmooth * 0.45);
    } else if (gx * gy > 0.0) {
        // Diagonal \  ~ blend NW/SE
        edgeBlend = mix(upscaled, (upscaled + nw + se) * (1.0/3.0), aaSmooth * 0.40);
    } else {
        // Diagonal /  ~ blend NE/SW
        edgeBlend = mix(upscaled, (upscaled + ne + sw) * (1.0/3.0), aaSmooth * 0.40);
    }

    upscaled.rgb = clamp(edgeBlend.rgb, minN.rgb, maxN.rgb);
    upscaled.a   = center.a;

    return upscaled;
}

        vec4 alphaEdgeReconstruct(int textureID, vec2 uv, vec2 texW, vec2 texH) {
            vec2 texelSize = vec2(1.0 / texW.x, 1.0 / texH.x);
            vec2 lo = texelSize * 1.5;
            vec2 hi = vec2(1.0) - texelSize * 1.5;

            vec4 center = getTextureColor(textureID, uv);
            if (center.a <= 0.0) return center;

            vec4 n = getTextureColor(textureID, clamp(uv + vec2( 0.0,        -texelSize.y), lo, hi));
            vec4 s = getTextureColor(textureID, clamp(uv + vec2( 0.0,         texelSize.y), lo, hi));
            vec4 e = getTextureColor(textureID, clamp(uv + vec2( texelSize.x,  0.0       ), lo, hi));
            vec4 w = getTextureColor(textureID, clamp(uv + vec2(-texelSize.x,  0.0       ), lo, hi));

            float minNeighborAlpha = min(min(n.a, s.a), min(e.a, w.a));
            if (minNeighborAlpha > 0.2) return center;

            float totalWeight = 0.0;
            float blurA       = 0.0;
            if (n.a > 0.5) { blurA += n.a; totalWeight += 1.0; }
            if (s.a > 0.5) { blurA += s.a; totalWeight += 1.0; }
            if (e.a > 0.5) { blurA += e.a; totalWeight += 1.0; }
            if (w.a > 0.5) { blurA += w.a; totalWeight += 1.0; }
            if (totalWeight > 0.0) blurA /= totalWeight;
            else blurA = center.a;

            float sharpA   = center.a + (center.a - blurA) * 3.0;
            float edgeOnly = smoothstep(0.0, 0.3, center.a);

            return vec4(center.rgb, clamp(mix(center.a, sharpA, edgeOnly), 0.0, 1.0));
        }

        vec4 iconPixel(int textureID, vec2 uv, vec2 texW, vec2 texH) {
            if (any(lessThan(uv, vec2(0.0001))) || any(greaterThan(uv, vec2(0.9999))))
                return vec4(0.0);

            vec2 texelSize = vec2(1.0 / texW.x, 1.0 / texH.x);
            vec2 lo        = texelSize * 1.5;
            vec2 hi        = vec2(1.0) - lo;

            vec4 ravu   = ravuSample(textureID, uv, texelSize, lo, hi);
            vec4 edge   = alphaEdgeReconstruct(textureID, uv, texW, texH);

            vec4 result = vec4(ravu.rgb, edge.a);
            result.rgb *= result.a;
            return result;
        }
        ';
}
