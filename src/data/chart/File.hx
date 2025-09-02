// This is the pure haxe version of HxBigIO's BigBytes by Chris AKA Dimensionscape

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
	@:runtime inline static function loadChart(inFile:String):Void {
		var str = ConstCharStar.fromString(inFile);
		_loadChart(str);
	}
	@:native("loadChart") static function _loadChart(inFile:ConstCharStar):Void;
	@:native("getNote") static function getNote(atIndex:Int64):MetaNote;
	@:native("getLength") static function getLength():Int64;
	@:native("destroyChart") static function destroyChart():Void;

	// For the chart editor (keep in mind, completely untested so this is implemented early)
	@:native("insertNote") static function insertNote(atIndex:Int64, value:Int64, autoflush:Bool):Void;
	@:native("removeNote") static function removeNote(atIndex:Int64, autoflush:Bool):Void;
}
#elseif hl
class File {
	@:hlNative("chart_file", "loadChart") public static function loadChart(inFile:String):Void {}

	@:hlNative("chart_file", "getNote") public static function getNote(atIndex:hl.I64):MetaNote {
		return 0;
	}

	@:hlNative("chart_file", "getLength") public static function getLength():hl.I64 {
		return 0;
	}

	@:hlNative("chart_file", "destroyChart") public static function destroyChart():Void {}

	// For the chart editor (keep in mind, completely untested so this is implemented early)
	@:hlNative("chart_file", "insertNote") static function insertNote(atIndex:hl.I64, value:hl.I64, autoflush:Bool):Void {}
	@:hlNative("chart_file", "removeNote") static function removeNote(atIndex:hl.I64, autoflush:Bool):Void {}
}
#end