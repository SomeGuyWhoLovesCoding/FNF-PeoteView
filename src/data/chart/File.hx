// This is the pure haxe version of HxBigIO's BigBytes by Chris AKA Dimensionscape

package data.chart;

import cpp.Int64;
import haxe.Int64 as HaxeInt64;
import cpp.SizeT;
import cpp.FILE;
import cpp.Pointer;
import cpp.NativeArray;
import cpp.Native;
import custom.cpp.*;

/**
	The chart data retrieved from a file.
	For now, the maximum possible note count for a chart file instance is around 2^56 (72,057,593,501,057,025). This is because `Array` has a max element count that depends on the element's size.
	That will be changed in the near future.
**/
@:cppFileCode("
#define _FILE_OFFSET_BITS 64
")
@:publicFields
class File {
	static inline var CHUNK_SIZE:Int = 268435455;

	private var data(default, null):Array<Array<Int64>>;
	private var file(default, null):FILE;

	var length(default, null):HaxeInt64;

	function new(inFile:String) {
		// Open the file

		file = Stdio.fopen(inFile, untyped "rb");

		// Calculate the file size

		Iostream.fseeki64(file, 0, 2);

		var len:HaxeInt64 = HaxeInt64.div(Iostream.ftelli64(file), 8);

		length = len;

		Iostream.fseeki64(file, 0, 0);

		data = [];

		// Now do the processing

		if (len > CHUNK_SIZE) {
			var size:SizeT = CHUNK_SIZE;

			//while (len > 0) { // This throws a weird compilation error of "Cannot compare cpp.Int64 and cpp.Int64"
			while (size > 0) {
				size = HaxeInt64.toInt(len);

				if (size == 0) {
					break;
				}

				if (len > CHUNK_SIZE) {
					size = CHUNK_SIZE;
				}

				var chunk:Array<Int64> = NativeArray.create(size);

				data.push(chunk);

				var buf:Pointer<Int64> = Pointer.ofArray(chunk);
				Stdio.fread(buf.raw, 8, size, file);

				len -= size;
			}
		} else {
			var shortLen = len.low;
			var chunk:Array<Int64> = NativeArray.create(shortLen);

			data.push(chunk);

			var buf:Pointer<Int64> = Pointer.ofArray(chunk);
			Stdio.fread(buf.raw, 8, shortLen, file);
		}

		// Close the file
		Stdio.fclose(file);
	}

	function getNote(atIndex:Int64):MetaNote {
		var index = HaxeInt64.divMod(atIndex, CHUNK_SIZE);
		var atChunk = NativeArray.unsafeGet(data, index.quotient.low);
		return NativeArray.unsafeGet(atChunk, index.modulus.low);
	}
}