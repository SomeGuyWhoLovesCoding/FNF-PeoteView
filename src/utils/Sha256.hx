package utils;

import haxe.io.Input;
import haxe.io.Bytes;

/**
	Streaming Sha256.
**/
class Sha256 {
	static var K:Array<Int> = [
		0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
		0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786, 0xFC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
		0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x6CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
		0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
		0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
		0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
	];

	public static function makeFromInput(input:Input, totalLength:Int):Bytes {
		var HASH:Array<Int> = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19];
		var W = new Array<Int>();
		W[64] = 0;
		var m = new Array<Int>();
		for (i in 0...16) m[i] = 0;

		var buf = Bytes.alloc(64);
		var processed = 0;
		
		while (processed + 64 <= totalLength) {
			input.readFullBytes(buf, 0, 64);
			for (i in 0...16) {
				m[i] = (buf.get(i*4) << 24) | (buf.get(i*4+1) << 16) | (buf.get(i*4+2) << 8) | buf.get(i*4+3);
			}
			processBlock(m, W, HASH);
			processed += 64;
		}

		var remaining = totalLength - processed;
		if (remaining > 0) input.readFullBytes(buf, 0, remaining);
		
		buf.set(remaining, 0x80);
		for (i in (remaining+1)...64) buf.set(i, 0);
		
		for (i in 0...16) {
			m[i] = (buf.get(i*4) << 24) | (buf.get(i*4+1) << 16) | (buf.get(i*4+2) << 8) | buf.get(i*4+3);
		}
		
		if (remaining >= 56) {
			processBlock(m, W, HASH);
			for (i in 0...14) m[i] = 0;
			m[14] = totalLength >>> 29;
			m[15] = (totalLength & 0x1FFFFFFF) << 3;
			processBlock(m, W, HASH);
		} else {
			for (i in (remaining+1)...14) m[i] = 0;
			m[14] = totalLength >>> 29;
			m[15] = (totalLength & 0x1FFFFFFF) << 3;
			processBlock(m, W, HASH);
		}

		var out = Bytes.alloc(32);
		var p = 0;
		for (i in 0...8) {
			out.set(p++, HASH[i] >>> 24);
			out.set(p++, (HASH[i] >> 16) & 0xFF);
			out.set(p++, (HASH[i] >> 8) & 0xFF);
			out.set(p++, HASH[i] & 0xFF);
		}
		return out;
	}

	static function processBlock(m:Array<Int>, W:Array<Int>, HASH:Array<Int>) {
		var a:Int = HASH[0], b:Int = HASH[1], c:Int = HASH[2], d:Int = HASH[3];
		var e:Int = HASH[4], f:Int = HASH[5], g:Int = HASH[6], h:Int = HASH[7];
		var T1, T2;
		
		for (j in 0...64) {
			if (j < 16) W[j] = m[j];
			else W[j] = safeAdd(safeAdd(safeAdd(Gamma1256(W[j - 2]), W[j - 7]), Gamma0256(W[j - 15])), W[j - 16]);
			T1 = safeAdd(safeAdd(safeAdd(safeAdd(h, Sigma1256(e)), Ch(e, f, g)), K[j]), W[j]);
			T2 = safeAdd(Sigma0256(a), Maj(a, b, c));
			h = g; g = f; f = e; e = safeAdd(d, T1);
			d = c; c = b; b = a; a = safeAdd(T1, T2);
		}
		
		HASH[0] = safeAdd(a, HASH[0]);
		HASH[1] = safeAdd(b, HASH[1]);
		HASH[2] = safeAdd(c, HASH[2]);
		HASH[3] = safeAdd(d, HASH[3]);
		HASH[4] = safeAdd(e, HASH[4]);
		HASH[5] = safeAdd(f, HASH[5]);
		HASH[6] = safeAdd(g, HASH[6]);
		HASH[7] = safeAdd(h, HASH[7]);
	}

	inline static function S(X, n) return (X >>> n) | (X << (32 - n));
	inline static function R(X, n) return (X >>> n);
	inline static function Ch(x, y, z) return ((x & y) ^ ((~x) & z));
	inline static function Maj(x, y, z) return ((x & y) ^ (x & z) ^ (y & z));
	inline static function Sigma0256(x) return (S(x, 2) ^ S(x, 13) ^ S(x, 22));
	inline static function Sigma1256(x) return (S(x, 6) ^ S(x, 11) ^ S(x, 25));
	inline static function Gamma0256(x) return (S(x, 7) ^ S(x, 18) ^ R(x, 3));
	inline static function Gamma1256(x) return (S(x, 17) ^ S(x, 19) ^ R(x, 10));
	inline static function safeAdd(x, y) {
		var lsw = (x & 0xFFFF) + (y & 0xFFFF);
		var msw = (x >> 16) + (y >> 16) + (lsw >> 16);
		return (msw << 16) | (lsw & 0xFFFF);
	}
}