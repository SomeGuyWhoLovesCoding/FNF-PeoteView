// This is the pure haxe version of HxBigIO's BigBytes by Chris AKA Dimensionscape

package data.chart;

#if cpp
import cpp.ConstCharStar;
import data.chart.StdVectorInt64;

/**
	The chart data retrieved from a file.
	The maximum possible note count for a chart file instance is the max amount of ram you have on your computer, divided by the byte size of the meta note.
**/
@:buildXml('<include name="../../../chartFileBuild.xml" />')
@:unreflective @:keep
@:include("./include/chart_file.h")
extern class File {
	@:runtime inline static function loadChart(inFile:String):Void {
		var str = ConstCharStar.fromString(inFile);
		_loadChart(str);
	}
	@:native("loadChart") static function _loadChart(inFile:ConstCharStar):Void;
	@:native("getNote") static function getNote(atIndex:Int64):MetaNote;
	@:native("getLength") static function getLength():Int64;
	@:native("destroyChart") static function destroyChart():Void;

	// For the chart editor (keep in mind, completely untested so this is implemented early)
	@:native("insertNote") static function insertNote(atIndex:Int64, value:Int64):Void;
	@:native("removeNote") static function removeNote(atIndex:Int64):Void;
	@:runtime inline static function insertNotes(atIndex:Int64, values:Array<MetaNote>):Void {
		var arr = StdVectorInt64.fromInt64Array(values);
		_insertNotes(atIndex, arr);
	}
	@:native("insertNotes") static function _insertNotes(atIndex:Int64, values:StdVectorInt64):Void;
	@:native("removeNotes") static function removeNotes(atIndex:Int64, count:Int64):Void;
}
#elseif hl
class File {
	@:runtime inline public static function loadChart(inFile:String):Void {
		var str = @:privateAccess inFile.toUtf8();
		_loadChart(str);
	}

	@:hlNative("chart_file", "loadChart") public static function _loadChart(inFile:hl.Bytes):Void {}

	@:hlNative("chart_file", "getNote") public static function getNote(atIndex:hl.I64):MetaNote {
		return 0;
	}

	@:hlNative("chart_file", "getLength") public static function getLength():hl.I64 {
		return 0;
	}

	@:hlNative("chart_file", "destroyChart") public static function destroyChart():Void {}

	// For the chart editor (keep in mind, completely untested so this is implemented early)
	@:hlNative("chart_file", "insertNote") static function insertNote(atIndex:hl.I64, value:hl.I64):Void {}
	@:hlNative("chart_file", "removeNote") static function removeNote(atIndex:hl.I64):Void {}
	@:runtime inline static function insertNotes(atIndex:Int64, values:Array<MetaNote>):Void {
		var nativeArray = new hl.NativeArray(values.length);
		for (i in 0...values.length) {
			nativeArray[i] = values[i];
		}
		_insertNotes(atIndex, nativeArray);
	}
	@:hlNative("chart_file", "insertNotes") static function _insertNotes(atIndex:hl.I64, values:hl.NativeArray<hl.I64>):Void {}
	@:hlNative("chart_file", "removeNotes") static function removeNotes(atIndex:hl.I64, count:hl.I64):Void {}
}
#end