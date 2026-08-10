package utils;

import haxe.io.Bytes;
import haxe.io.Input;
import haxe.io.Output;
import haxe.ds.Vector;

class LZ4 {
	private static inline var MINMATCH = 4;
	private static inline var HASH_LOG = 17;
	private static inline var HASH_SIZE = 1 << HASH_LOG;

	private static var hashTable:Vector<Int> = null;
	private static var hashTableGen:Vector<Int> = null; // NEW: Generation tracking
	private static var currentGen:Int = 0;
	private static var compressStreamBuffer:Bytes = null;

	public static function compress(src:Bytes):Bytes {
		var srcLen = src.length;
		if (srcLen == 0)
			return Bytes.alloc(0);
		var maxOutLen = srcLen + Std.int(srcLen / 255) + 16;
		var dst = Bytes.alloc(maxOutLen);
		var len = compressTo(src, dst, 0, srcLen, 0);
		//BOTTLENECK: mid Bytes.sub allocates a second full-size buffer + memcpy after every compress; doubles peak memory and GC churn | FIX: size dst exactly and return it, or reuse a persistent scratch buffer
		return dst.sub(0, len);
	}

	public static function compressTo(src:Bytes, dst:Bytes, srcBase:Int = 0, srcLen:Int = -1, dstBase:Int = 0):Int {
		if (srcLen < 0)
			srcLen = src.length - srcBase;
		if (srcLen == 0)
			return 0;

		if (hashTable == null) {
			hashTable = new Vector<Int>(HASH_SIZE);
			hashTableGen = new Vector<Int>(HASH_SIZE);
		}
		currentGen++;
		if (currentGen == 0) { // Prevent overflow after millions of compressions
			var i = 0;
			while (i < HASH_SIZE) {
				hashTableGen[i] = 0;
				i++;
			}
			currentGen = 1;
		}

		var srcIdx = srcBase, dstIdx = dstBase, anchor = srcBase;
		var matchLimit = srcBase + srcLen - MINMATCH;
		var endLimit = srcBase + srcLen;

		while (srcIdx <= matchLimit) {
			var seq = read32(src, srcIdx);
			var hash = (seq * -1640531535) >>> (32 - HASH_LOG);

			// OPTIMIZATION: Check generation instead of clearing the whole table
			var matchIdx = (hashTableGen[hash] == currentGen) ? hashTable[hash] : -1;
			hashTable[hash] = srcIdx;
			hashTableGen[hash] = currentGen;

			if (matchIdx >= srcBase && srcIdx - matchIdx < 65536 && read32(src, matchIdx) == seq) {
				while (srcIdx > anchor && matchIdx > srcBase && src.get(srcIdx - 1) == src.get(matchIdx - 1)) {
					srcIdx--;
					matchIdx--;
				}

				var litLen = srcIdx - anchor;
				var offset = srcIdx - matchIdx;
				var matchLen = MINMATCH;
				while (srcIdx + matchLen + 4 <= endLimit && read32(src, srcIdx + matchLen) == read32(src, matchIdx + matchLen))
					matchLen += 4;
				while (srcIdx + matchLen < endLimit && src.get(srcIdx + matchLen) == src.get(matchIdx + matchLen))
					matchLen++;

				var tokenPos = dstIdx++;
				var ml = matchLen - MINMATCH;
				var token = (litLen >= 15 ? 0xF0 : litLen << 4) | (ml >= 15 ? 0x0F : ml);
				dst.set(tokenPos, token);

				if (litLen >= 15) {
					var len = litLen - 15;
					while (len >= 255) {
						dst.set(dstIdx++, 255);
						len -= 255;
					}
					dst.set(dstIdx++, len);
				}
				if (litLen > 0) {
					dst.blit(dstIdx, src, anchor, litLen);
					dstIdx += litLen;
				}
				dst.set(dstIdx++, offset & 0xFF);
				dst.set(dstIdx++, (offset >> 8) & 0xFF);
				if (ml >= 15) {
					var len = ml - 15;
					while (len >= 255) {
						dst.set(dstIdx++, 255);
						len -= 255;
					}
					dst.set(dstIdx++, len);
				}

				var nextIdx = srcIdx + matchLen;
				srcIdx++;
				while (srcIdx < nextIdx) {
					if (srcIdx <= matchLimit) {
						var seq2 = read32(src, srcIdx);
						var hash2 = (seq2 * -1640531535) >>> (32 - HASH_LOG);
						hashTable[hash2] = srcIdx;
						hashTableGen[hash2] = currentGen;
					}
					srcIdx++;
				}
				anchor = srcIdx;
				continue;
			}
			srcIdx += 1;
		}

		var lastLitLen = endLimit - anchor;
		var tokenPos = dstIdx++;
		var token = lastLitLen >= 15 ? 0xF0 : lastLitLen << 4;
		dst.set(tokenPos, token);
		if (lastLitLen >= 15) {
			var len = lastLitLen - 15;
			while (len >= 255) {
				dst.set(dstIdx++, 255);
				len -= 255;
			}
			dst.set(dstIdx++, len);
		}
		if (lastLitLen > 0) {
			dst.blit(dstIdx, src, anchor, lastLitLen);
			dstIdx += lastLitLen;
		}

		return dstIdx - dstBase;
	}

	public static function compressStream(input:Input, totalLen:Int, out:Output):Int {
		if (totalLen == 0)
			return 0;

		var WINDOW_SIZE = 65536;
		var CHUNK_SIZE = 16384;
		var BUF_SIZE = WINDOW_SIZE + CHUNK_SIZE + 16;

		if (compressStreamBuffer == null || compressStreamBuffer.length < BUF_SIZE) {
			compressStreamBuffer = Bytes.alloc(BUF_SIZE);
		}
		var buf = compressStreamBuffer;

		var bufLen = 0;
		var bufIdx = 0;
		var globalPos = 0;
		var anchor = 0;
		var writtenBytes = 0;

		if (hashTable == null) {
			hashTable = new Vector<Int>(HASH_SIZE);
			hashTableGen = new Vector<Int>(HASH_SIZE);
		}

		// OPTIMIZATION: Increment generation instead of clearing 131,072 elements!
		currentGen++;
		if (currentGen == 0) {
			var i = 0;
			while (i < HASH_SIZE) {
				hashTableGen[i] = 0;
				i++;
			}
			currentGen = 1;
		}

		var toRead = totalLen < CHUNK_SIZE ? totalLen : CHUNK_SIZE;
		input.readFullBytes(buf, 0, toRead);
		bufLen = toRead;

		while (globalPos < totalLen) {
			if (bufIdx + 16 > bufLen && globalPos + (bufLen - bufIdx) < totalLen) {
				if (bufIdx - anchor > 32768) {
					var litLen = bufIdx - anchor;
					out.writeByte(0xF0);
					writtenBytes++;
					var len = litLen - 15;
					while (len >= 255) {
						out.writeByte(255);
						writtenBytes++;
						len -= 255;
					}
					out.writeByte(len);
					writtenBytes++;
					out.writeBytes(buf, anchor, litLen);
					writtenBytes += litLen;
					anchor = bufIdx;
				}

				if (bufIdx > WINDOW_SIZE) {
					var shift = bufIdx - WINDOW_SIZE;
					buf.blit(0, buf, shift, bufLen - shift);
					bufLen -= shift;
					bufIdx -= shift;
					anchor -= shift;
				}

				var endGlobalPos = globalPos + (bufLen - bufIdx);
				toRead = totalLen - endGlobalPos;
				if (toRead > CHUNK_SIZE)
					toRead = CHUNK_SIZE;

				var available = BUF_SIZE - bufLen;
				if (toRead > available)
					toRead = available;

				if (toRead > 0) {
					input.readFullBytes(buf, bufLen, toRead);
					bufLen += toRead;
				}
			}

			var matchLimit = bufLen - MINMATCH;
			var endLimit = bufLen;

			while (bufIdx <= matchLimit && globalPos < totalLen) {
				if (bufIdx + 16 > bufLen && globalPos + (bufLen - bufIdx) < totalLen)
					break;

				var seq = read32(buf, bufIdx);
				var hash = (seq * -1640531535) >>> (32 - HASH_LOG);

				// OPTIMIZATION: Check generation to avoid stale matches
				var matchGlobal = (hashTableGen[hash] == currentGen) ? hashTable[hash] : -1;
				hashTable[hash] = globalPos;
				hashTableGen[hash] = currentGen;

				if (matchGlobal != -1 && globalPos - matchGlobal <= 65535) {
					var offset = globalPos - matchGlobal;
					var matchBufIdx = bufIdx - offset;

					if (matchBufIdx >= 0 && read32(buf, matchBufIdx) == seq) {
						while (bufIdx > anchor && matchBufIdx > 0 && buf.get(bufIdx - 1) == buf.get(matchBufIdx - 1)) {
							bufIdx--;
							matchBufIdx--;
							globalPos--;
						}

						var litLen = bufIdx - anchor;
						var matchLen = MINMATCH;
						while (bufIdx + matchLen + 4 <= endLimit && read32(buf, bufIdx + matchLen) == read32(buf, matchBufIdx + matchLen))
							matchLen += 4;
						while (bufIdx + matchLen < endLimit && buf.get(bufIdx + matchLen) == buf.get(matchBufIdx + matchLen))
							matchLen++;

						var ml = matchLen - MINMATCH;
						var token = (litLen >= 15 ? 0xF0 : litLen << 4) | (ml >= 15 ? 0x0F : ml);
						//BOTTLENECK: high per-byte virtual Output.writeByte for every token/offset/literal byte over the whole stream; billions of calls on multi-GB charts | FIX: accumulate tokens in a Bytes block and flush with writeBytes
						out.writeByte(token);
						writtenBytes++;

						if (litLen >= 15) {
							var len = litLen - 15;
							while (len >= 255) {
								out.writeByte(255);
								writtenBytes++;
								len -= 255;
							}
							out.writeByte(len);
							writtenBytes++;
						}
						if (litLen > 0) {
							out.writeBytes(buf, anchor, litLen);
							writtenBytes += litLen;
						}
						out.writeByte(offset & 0xFF);
						out.writeByte((offset >> 8) & 0xFF);
						writtenBytes += 2;
						if (ml >= 15) {
							var len = ml - 15;
							while (len >= 255) {
								out.writeByte(255);
								writtenBytes++;
								len -= 255;
							}
							out.writeByte(len);
							writtenBytes++;
						}

						var nextBufIdx = bufIdx + matchLen;
						var nextGlobalPos = globalPos + matchLen;
						bufIdx++;
						globalPos++;
						while (bufIdx < nextBufIdx) {
							if (bufIdx <= matchLimit) {
								var seq2 = read32(buf, bufIdx);
								var hash2 = (seq2 * -1640531535) >>> (32 - HASH_LOG);
								hashTable[hash2] = globalPos;
								hashTableGen[hash2] = currentGen;
							}
							bufIdx++;
							globalPos++;
						}
						anchor = bufIdx;
						continue;
					}
				}
				bufIdx++;
				globalPos++;
			}
		}

		var lastLitLen = bufLen - anchor;
		var token = lastLitLen >= 15 ? 0xF0 : lastLitLen << 4;
		out.writeByte(token);
		writtenBytes++;
		if (lastLitLen >= 15) {
			var len = lastLitLen - 15;
			while (len >= 255) {
				out.writeByte(255);
				writtenBytes++;
				len -= 255;
			}
			out.writeByte(len);
			writtenBytes++;
		}
		if (lastLitLen > 0) {
			out.writeBytes(buf, anchor, lastLitLen);
			writtenBytes += lastLitLen;
		}

		return writtenBytes;
	}

	public static function decompress(src:Bytes, outSize:Int = -1):Bytes {
		var srcLen = src.length;
		if (srcLen == 0)
			return Bytes.alloc(0);
		//BOTTLENECK: mid output allocated twice (oversized guess + Bytes.sub copy), doubling peak memory for large decompressions | FIX: allocate exact size once and return without the sub copy
		var out = outSize > 0 ? Bytes.alloc(outSize) : Bytes.alloc(srcLen * 4 < 1024 ? 1024 : srcLen * 4);
		var outIdx = decompressTo(src, out, 0, srcLen, 0);
		return out.sub(0, outIdx);
	}

	public static function decompressTo(src:Bytes, out:Bytes, srcBase:Int = 0, srcLen:Int = -1, outBase:Int = 0):Int {
		if (srcLen < 0)
			srcLen = src.length - srcBase;
		if (srcLen == 0)
			return 0;

		var outIdx = outBase;
		var srcIdx = srcBase;
		var srcEnd = srcBase + srcLen;

		while (srcIdx < srcEnd) {
			var token = src.get(srcIdx++);
			var litLen = token >> 4;
			var matchLen = token & 0x0F;
			if (litLen == 15) {
				var b = 0;
				do {
					if (srcIdx >= srcEnd)
						throw "LZ4: Unexpected EOF in litLen";
					b = src.get(srcIdx++);
					litLen += b;
				} while (b == 255);
			}
			if (litLen > 0) {
				if (srcIdx + litLen > srcEnd)
					throw "LZ4: Literal exceeds source";
				if (outIdx + litLen > out.length)
					throw "LZ4: Output exceeds expected size";
				out.blit(outIdx, src, srcIdx, litLen);
				srcIdx += litLen;
				outIdx += litLen;
			}
			if (srcIdx >= srcEnd)
				break;
			if (srcIdx + 2 > srcEnd)
				throw "LZ4: Unexpected EOF in offset";
			var offset = src.get(srcIdx++) | (src.get(srcIdx++) << 8);
			if (offset == 0 || outIdx - outBase < offset)
				throw "LZ4: Invalid offset " + offset;
			if ((token & 0x0F) == 15) {
				var b = 0;
				do {
					if (srcIdx >= srcEnd)
						throw "LZ4: Unexpected EOF in matchLen";
					b = src.get(srcIdx++);
					matchLen += b;
				} while (b == 255);
			}
			matchLen += MINMATCH;

			var matchPos = outIdx - offset;
			if (outIdx + matchLen > out.length)
				throw "LZ4: Output exceeds expected size";
			if (offset >= matchLen) {
				out.blit(outIdx, out, matchPos, matchLen);
			} else {
				out.blit(outIdx, out, matchPos, offset);
				var copied = offset;
				while (copied < matchLen) {
					var chunk = copied < matchLen - copied ? copied : matchLen - copied;
					out.blit(outIdx + copied, out, matchPos, chunk);
					copied += chunk;
				}
			}
			outIdx += matchLen;
		}
		return outIdx - outBase;
	}

	public static function decompressFromInput(input:Input, out:Bytes, outSize:Int):Int {
		var outIdx = 0;
		var outEnd = outSize;
		while (true) {
			var token;
			try {
				token = input.readByte();
			} catch (e:haxe.io.Eof) {
				break;
			}
			var litLen = token >> 4;
			var matchLen = token & 0x0F;
			if (litLen == 15) {
				var b = 0;
				do {
					b = input.readByte();
					litLen += b;
				} while (b == 255);
			}
			if (litLen > 0) {
				if (outIdx + litLen > outEnd)
					throw "LZ4: Output exceeds expected size";
				input.readFullBytes(out, outIdx, litLen);
				outIdx += litLen;
			}
			var b1;
			try {
				b1 = input.readByte();
			} catch (e:haxe.io.Eof) {
				break;
			}
			var offset = b1 | (input.readByte() << 8);
			if (offset == 0 || outIdx < offset)
				throw "LZ4: Invalid offset " + offset;
			if (matchLen == 15) {
				var b = 0;
				do {
					b = input.readByte();
					matchLen += b;
				} while (b == 255);
			}
			matchLen += MINMATCH;

			var matchPos = outIdx - offset;
			if (outIdx + matchLen > outEnd)
				throw "LZ4: Output exceeds expected size";
			if (offset >= matchLen) {
				out.blit(outIdx, out, matchPos, matchLen);
			} else {
				out.blit(outIdx, out, matchPos, offset);
				var copied = offset;
				while (copied < matchLen) {
					var chunk = copied < matchLen - copied ? copied : matchLen - copied;
					out.blit(outIdx + copied, out, matchPos, chunk);
					copied += chunk;
				}
			}
			outIdx += matchLen;
		}
		return outIdx;
	}

	//BOTTLENECK: mid 4 bounds-checked Bytes.get calls per 32-bit load inside the hot compress/match loops (byte-level) | FIX: unaligned native int load via cpp.Pointer / hl BytesInt32
	private static inline function read32(b:Bytes, i:Int):Int {
		return b.get(i) | (b.get(i + 1) << 8) | (b.get(i + 2) << 16) | (b.get(i + 3) << 24);
	}
}
