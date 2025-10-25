// This was a pure hxcpp-only haxe version of HxBigIO's BigBytes by Chris AKA Dimensionscape that is now turned into an extern compatible with both hxcpp and hashlink.

package data.chart;

#if cpp
import cpp.ConstCharStar;

/**
	The chart data retrieved from a file.
	The maximum possible note count for a chart file instance is the max amount of ram you have on your computer, divided by the byte size of the meta note.
**/
@:buildXml('<include name="../../../chartFileBuild.xml" />')
@:unreflective @:keep
@:include("./include/chart_file.h")
extern class File {
	@:native("remap") static function remap(newLength:Int64):Bool;

	@:runtime inline static function loadChart(inFile:String):Void {
		var str = ConstCharStar.fromString(inFile);
		_loadChart(str);
	}
	@:native("loadChart") static function _loadChart(inFile:ConstCharStar):Void;
	@:native("getNote") static function getNote(atIndex:Int64):MetaNote;
	@:native("getLength") static function getLength():Int64;
	@:native("destroyChart") static function destroyChart():Void;

	@:runtime inline public static function insertNote(value:MetaNote):Void {
		var atIndex = findClosestNoteIndexByTime(value.position);
		//Sys.println(atIndex);
		_insertNote(atIndex, value);
	}
	@:native("insertNote") static function _insertNote(atIndex:Int64, value:Int64):Void;
	@:native("removeNote") static function removeNote(atIndex:Int64):Void;

	@:runtime inline public static function insertNotes(arr:Array<MetaNote>):Void {
		//remap(getLength() + arr.length);
		/*for (value in arr) {
			var atIndex = findClosestNoteIndexByTime(value.position);
			//Sys.println(atIndex);
			_insertNote(atIndex, value);
		}*/
		var values = StdVectorInt64.fromInt64Array(arr);
		_insertNotes(values);
	}
	@:native("insertNotes") static function _insertNotes(values:StdVectorInt64):Void;

	@:runtime inline public static function removeNotes(arr:Array<MetaNote>):Void {
		//remap(getLength() + arr.length);
		/*for (value in arr) {
			var atIndex = findClosestNoteIndexByTime(value.position);
			//Sys.println(atIndex);
			_insertNote(atIndex, value);
		}*/
		var values = StdVectorInt64.fromInt64Array(arr);
		_removeNotes(values);
	}
	@:native("removeNotes") static function _removeNotes(values:StdVectorInt64):Void;

	@:native("setNote") static function setNote(atIndex:Int64, value:Int64):Void; // For the flags

	/**
		Find the index of a note by its time using binary search.
		Returns the exact index if found, or the index where the note should be inserted if not found.
		@param time The time to search for
		@return The index of the note at the specified time, or insertion point if not found
	**/
	@:runtime inline static function findNoteIndexByTime(time:Int64):Int64 {
		var length = getLength();
		if (length == 0) return 0;

		var left:Int64 = 0;
		var right:Int64 = length - 1;
		var result:Int64 = 0;
		var unsuccessful:Bool = false;

		while (left <= right) {
			var mid:Int64 = left + ((right - left) >> 1);
			var note = getNote(mid);
			var noteTime = note.position; // Assuming MetaNote has a time property

			if (noteTime == time) {
				result = mid;
				unsuccessful = true;
				break;
			} else if (noteTime < time) {
				left = mid + 1;
			} else {
				right = mid - 1;
			}
		}

		if (!unsuccessful) result = left;
		// Return insertion point (where the note should be inserted)
		return result;
	}

	/**
		Find the closest note index to a given time.
		@param time The time to search for
		@return The index of the closest note, or -1 if no notes exist
	**/
	@:runtime inline static function findClosestNoteIndexByTime(time:Int64):Int64 {
		var length = getLength();
		if (length == 0) return -1;

		var insertionPoint = findNoteIndexByTime(time);

		var result:Int64 = 0;

		// If exact match or insertion point is at the end
		if (insertionPoint >= length) {
			result = length - 1;
		} else if (insertionPoint != 0) { // If insertion point is at the beginning
			// Compare distances to previous and current note
			var prevNote = getNote(insertionPoint - 1);
			var currNote = getNote(insertionPoint);

			var prevDistance = (time - prevNote.position);
			if (prevDistance < 0) prevDistance = -prevDistance;
			var currDistance = (time - currNote.position);
			if (currDistance < 0) currDistance = -prevDistance;

			result = (prevDistance <= currDistance) ? insertionPoint - 1 : insertionPoint;
		}

		return result;
	}
}
#elseif hl
class File {
	@:hlNative("chart_file", "remap") public static function remap(newLength:Int64):Bool {
		return false;
	}

	@:hlNative("chart_file", "loadChart") public static function loadChart(inFile:String):Void {}

	@:hlNative("chart_file", "getNote") public static function getNote(atIndex:hl.I64):MetaNote {
		return 0;
	}

	@:hlNative("chart_file", "getLength") public static function getLength():hl.I64 {
		return 0;
	}

	@:hlNative("chart_file", "destroyChart") public static function destroyChart():Void {}

	// For the chart editor (keep in mind, this is implemented early because of boredom and I wanted to)
	inline public static function insertNote(value:MetaNote):Void {
		var atIndex = findClosestNoteIndexByTime(value.position);
		//Sys.println(atIndex);
		_insertNote(atIndex, value);
	}
	@:hlNative("chart_file", "insertNote") static function _insertNote(atIndex:hl.I64, value:hl.I64):Void {}
	@:hlNative("chart_file", "removeNote") public static function removeNote(atIndex:hl.I64):Void {}

	@:hlNative("chart_file", "setNote") public static function setNote(atIndex:hl.I64, value:hl.I64):Void {}; // For the flags

	inline public static function insertNotes(arr:Array<MetaNote>):Void {
		// Turns out it wasn't from here and inside `removeNotes`. It's from the array inserts being slow. WOW am I smoking.
		//var stamp = haxe.Timer.stamp();
		var bytes:hl.Bytes = hl.Bytes.getArray(arr);
		//Sys.println('Fuck you. Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
		_insertNotes(bytes, arr.length);
	}
	@:hlNative("chart_file", "insertNotes") public static function _insertNotes(values:hl.Bytes, length:hl.I64):Void {}

	inline public static function removeNotes(arr:Array<MetaNote>):Void {
		//var stamp = haxe.Timer.stamp();
		var bytes:hl.Bytes = hl.Bytes.getArray(arr);
		//Sys.println('Fuck you. Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
		_removeNotes(bytes, arr.length);
	}
	@:hlNative("chart_file", "removeNotes") public static function _removeNotes(values:hl.Bytes, length:hl.I64):Void {}

	/**
		Find the index of a note by its time using binary search.
		Returns the exact index if found, or the index where the note should be inserted if not found.
		@param time The time to search for
		@return The index of the note at the specified time, or insertion point if not found
	**/
	public static function findNoteIndexByTime(time:Int64):hl.I64 {
		var length = getLength();
		if (length == 0) return 0;

		var left:hl.I64 = 0;
		var right:hl.I64 = length - 1;

		while (left <= right) {
			var mid:hl.I64 = left + ((right - left) >> 1);
			var note = getNote(mid);
			var noteTime = note.position; // Assuming MetaNote has a time property

			if (noteTime == time) {
				return mid;
			} else if (noteTime < time) {
				left = mid + 1;
			} else {
				right = mid - 1;
			}
		}

		// Return insertion point (where the note should be inserted)
		return left;
	}

	/**
		Find the closest note index to a given time.
		@param time The time to search for
		@return The index of the closest note, or -1 if no notes exist
	**/
	inline public static function findClosestNoteIndexByTime(time:Int64):Int64 {
		var length = getLength();
		if (length == 0) return -1;

		var insertionPoint = findNoteIndexByTime(time);

		var result:Int64 = 0;

		// If exact match or insertion point is at the end
		if (insertionPoint >= length) {
			result = length - 1;
		} else if (insertionPoint != 0) { // If insertion point is at the beginning
			// Compare distances to previous and current note
			var prevNote = getNote(insertionPoint - 1);
			var currNote = getNote(insertionPoint);

			var prevDistance = (time - prevNote.position);
			if (prevDistance < 0) prevDistance = -prevDistance;
			var currDistance = (time - currNote.position);
			if (currDistance < 0) currDistance = -prevDistance;

			result = (prevDistance <= currDistance) ? insertionPoint - 1 : insertionPoint;
		}

		return result;
	}
}
#end
