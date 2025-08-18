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
}
#elseif hl
class File {
	@:runtime inline public static function loadChart(inFile:String):Void {
		var str = @:privateAccess inFile.toUtf8();
		_loadChart(str);
	}

	@:native("loadChart") public static function _loadChart(inFile:hl.Bytes):Void {}

	@:native("getNote") public static function getNote(atIndex:hl.I64):MetaNote {
		return 0;
	}

	@:native("getLength") public static function getLength():hl.I64 {
		return 0;
	}

	@:native("destroyChart") public static function destroyChart():Void {}
}
#end