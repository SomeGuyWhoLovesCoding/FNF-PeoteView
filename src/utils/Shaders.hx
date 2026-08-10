package utils;

/**
 * @since Development
**/
@:publicFields
class Shaders {
	//BOTTLENECK: [mid] upscale fragment shader costs ~17 texture taps/pixel (bicubic ravuSample + 4-tap alphaEdgeReconstruct + 8-tap diagonalSnap with ~30 color-diff comparisons) applied to every character/icon sprite when upscale is enabled -> heavy fill-rate cost | FIX: reduce taps with early-out edge masking, share fetches between passes, or run upscale on a lower-res intermediate target
	static inline var UPSCALE_FRAGMENT_SHADER = '
		vec4 ravuSample(int textureID, vec2 uv, vec2 texelSize, vec2 lo, vec2 hi) {
			// Bicubic interpolation
			vec2 texPos  = uv / texelSize - 0.5;
			vec2 texPos1 = floor(texPos);
			vec2 phase   = texPos - texPos1;

			vec2 ph2 = phase * phase;
			vec2 ph3 = ph2 * phase;

			vec2 w0 = -0.5*ph3 + ph2 - 0.5*phase;
			vec2 w1 =  1.5*ph3 - 2.5*ph2 + 1.0;
			vec2 w2 = -1.5*ph3 + 2.0*ph2 + 0.5*phase;
			vec2 w3 =  0.5*ph3 - 0.5*ph2;

			vec2 wA = w0 + w1;
			vec2 wB = w2 + w3;

			vec2 uvA = clamp((texPos1 + w1/wA)*texelSize, lo, hi);
			vec2 uvB = clamp((texPos1 + 2.0 + w3/wB)*texelSize, lo, hi);

			vec4 sAA = getTextureColor(textureID, uvA);
			vec4 sBA = getTextureColor(textureID, vec2(uvB.x, uvA.y));
			vec4 sAB = getTextureColor(textureID, vec2(uvA.x, uvB.y));
			vec4 sBB = getTextureColor(textureID, uvB);

			float hA = wA.x/(wA.x + wB.x);
			float hB = wA.y/(wA.y + wB.y);
			vec4 upscaled = mix(mix(sBB, sAB, hA), mix(sBA, sAA, hA), hB);

			// Cardinal neighbors for Laplacian
			vec4 center = getTextureColor(textureID, uv);
			vec4 nc = getTextureColor(textureID, clamp(uv + vec2(0.0, -texelSize.y), lo, hi));
			vec4 sc = getTextureColor(textureID, clamp(uv + vec2(0.0,  texelSize.y), lo, hi));
			vec4 ec = getTextureColor(textureID, clamp(uv + vec2( texelSize.x, 0.0), lo, hi));
			vec4 wc = getTextureColor(textureID, clamp(uv + vec2(-texelSize.x, 0.0), lo, hi));

			// Min/Max for clamping
			vec3 minN = min(center.rgb, min(min(nc.rgb, sc.rgb), min(ec.rgb, wc.rgb)));
			vec3 maxN = max(center.rgb, max(max(nc.rgb, sc.rgb), max(ec.rgb, wc.rgb)));

			float px = length(fwidth(uv));
			float lapScale = clamp(px*600.0, 0.3, 1.0);

			vec3 lap = (center.rgb*4.0 - (nc.rgb + sc.rgb + ec.rgb + wc.rgb)) * lapScale;
			float edgeDist = min(min(uv.x,1.0-uv.x), min(uv.y,1.0-uv.y));
			float seamMask = smoothstep(0.0, px*6.0, edgeDist);

			vec3 sharp = clamp(upscaled.rgb + lap*seamMask, minN, maxN);

			// Anti-aliasing blend
			vec3 LUM = vec3(0.299,0.587,0.114);
			float lumN = dot(nc.rgb, LUM);
			float lumS = dot(sc.rgb, LUM);
			float lumE = dot(ec.rgb, LUM);
			float lumW = dot(wc.rgb, LUM);

			float lapMag = length(lap);
			float aaSmooth = smoothstep(0.15, 0.5, lapMag);

			vec3 edgeBlend = (abs(lumN-lumS) < abs(lumE-lumW))
							? mix(sharp, (sharp + nc.rgb + sc.rgb)/3.0, aaSmooth*0.25)
							: mix(sharp, (sharp + ec.rgb + wc.rgb)/3.0, aaSmooth*0.25);

			return vec4(clamp(edgeBlend, minN, maxN), center.a);
		}

		// Compute maximum color difference instead of luminance
		float cDiff(vec4 a, vec4 b) {
			vec3 d = abs(a.rgb - b.rgb);
			return max(max(d.r, d.g), d.b);
		}

		vec4 diagonalSnap(int textureID, vec2 uv, vec2 ds, vec4 current) {
			// fetch neighbors
			vec4 n  = getTextureColor(textureID, clamp(uv + ds * vec2( 0.0, -1.0), 0.0, 1.0));
			vec4 s  = getTextureColor(textureID, clamp(uv + ds * vec2( 0.0,  1.0), 0.0, 1.0));
			vec4 e  = getTextureColor(textureID, clamp(uv + ds * vec2( 1.0,  0.0), 0.0, 1.0));
			vec4 w  = getTextureColor(textureID, clamp(uv + ds * vec2(-1.0,  0.0), 0.0, 1.0));
			vec4 ne = getTextureColor(textureID, clamp(uv + ds * vec2( 1.0, -1.0), 0.0, 1.0));
			vec4 nw = getTextureColor(textureID, clamp(uv + ds * vec2(-1.0, -1.0), 0.0, 1.0));
			vec4 se = getTextureColor(textureID, clamp(uv + ds * vec2( 1.0,  1.0), 0.0, 1.0));
			vec4 sw = getTextureColor(textureID, clamp(uv + ds * vec2(-1.0,  1.0), 0.0, 1.0));

			float px = length(fwidth(uv));
			float T  = mix(0.18, 0.08, clamp(px * 800.0, 0.0, 1.0));

			bool diagPosPair = cDiff(ne, sw) < T;
			bool diagNegPair = cDiff(nw, se) < T;
			bool vertEdge    = cDiff(n, s) > T;
			bool horizEdge   = cDiff(e, w) > T;

			bool cLikeN  = cDiff(current, n)  < T;
			bool cLikeS  = cDiff(current, s)  < T;
			bool cLikeE  = cDiff(current, e)  < T;
			bool cLikeW  = cDiff(current, w)  < T;
			bool cLikeNE = cDiff(current, ne) < T;
			bool cLikeSW = cDiff(current, sw) < T;
			bool cLikeNW = cDiff(current, nw) < T;
			bool cLikeSE = cDiff(current, se) < T;

			vec4 result = current;

			// 45-degree diagonals
			if (diagNegPair && vertEdge && horizEdge) {
				if (cLikeNW && !cLikeN && !cLikeW && (cLikeS || cLikeE)) result = nw;
				if (cLikeSE && !cLikeS && !cLikeE && (cLikeN || cLikeW)) result = se;
			}
			if (diagPosPair && vertEdge && horizEdge) {
				if (cLikeNE && !cLikeN && !cLikeE && (cLikeS || cLikeW)) result = ne;
				if (cLikeSW && !cLikeS && !cLikeW && (cLikeN || cLikeE)) result = sw;
			}

			// 2:1 shallow slopes
			bool strongVert = vertEdge && (cDiff(n,s) > T * 1.5);
			bool weakHoriz  = horizEdge && (cDiff(e,w) < T * 1.5);
			if (strongVert && weakHoriz) {
				result = (cLikeN && cLikeNW && !cLikeW && cLikeS) ? n  : result;
				result = (cLikeS && cLikeSE && !cLikeE && cLikeN) ? s  : result;
				result = (cLikeN && cLikeNE && !cLikeE && cLikeS) ? n  : result;
				result = (cLikeS && cLikeSW && !cLikeW && cLikeN) ? s  : result;
			}

			// 2:1 steep slopes
			bool strongHoriz = horizEdge && (cDiff(e,w) > T * 1.5);
			bool weakVert    = vertEdge && (cDiff(n,s) < T * 1.5);
			if (strongHoriz && weakVert) {
				result = (cLikeW && cLikeSW && !cLikeS && cLikeE) ? w  : result;
				result = (cLikeE && cLikeNE && !cLikeN && cLikeW) ? e  : result;
				result = (cLikeW && cLikeNW && !cLikeN && cLikeE) ? w  : result;
				result = (cLikeE && cLikeSE && !cLikeS && cLikeW) ? e  : result;
			}

			result.a = current.a;
			return result;
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

			float sharpA   = center.a + (center.a - blurA) * 1.2;
			float edgeOnly = smoothstep(0.0, 0.2, center.a);

			return vec4(center.rgb, clamp(mix(center.a, sharpA, edgeOnly), 0.0, 1.0));
		}

		vec4 iconPixel(int textureID, vec2 uv, vec2 texW, vec2 texH) {
			if (any(lessThan(uv, vec2(0.0001))) || any(greaterThan(uv, vec2(0.9999))))
				return vec4(0.0);

			vec2 texelSize = vec2(1.0 / texW.x, 1.0 / texH.x);
			vec2 lo        = texelSize * 1.5;
			vec2 hi        = vec2(1.0) - lo;

			vec4 ravu = ravuSample(textureID, uv, texelSize, lo, hi);
			vec4 edge = alphaEdgeReconstruct(textureID, uv, texW, texH);

			vec4 result = vec4(ravu.rgb, edge.a);
			result      = diagonalSnap(textureID, uv, texelSize, result);
			result.rgb *= result.a;
			return result;
		}
		';
}
