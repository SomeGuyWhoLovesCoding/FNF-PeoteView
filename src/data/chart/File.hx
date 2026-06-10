package data.chart;

/**
 * @since Development
**/
#if cpp
import cpp.ConstCharStar;

@:buildXml('<include name="../../../chartFileBuild.xml" />')
@:unreflective @:keep
@:include("./include/chart_file.h")
extern class File {
	@:native("remap") static function remap(newLength:Int64):Bool;

	@:runtime inline static function loadChart(inFile:String):Void {
		var str = ConstCharStar.fromString(inFile);
		_loadChart(str);
	}
	@:native("loadChart")                  static function _loadChart(inFile:ConstCharStar):Void;
	@:native("getNote")                    static function getNote(atIndex:Int64):MetaNote;
	@:native("setNote")                    static function setNote(atIndex:Int64, value:Int64):Void;
	@:native("insertNote")                 static function insertNote(atGlobalPosition:Int64, duration:Int, index:Int, type:Int):Void;
	@:native("removeNote")                 static function removeNote(atIndex:Int64):Void;
	@:native("getLength")                  static function getLength():Int64;
	@:native("destroyChart")               static function destroyChart():Void;
	@:native("getTimeCorrectionForIndex")  static function getTimeCorrectionForIndex(index:Int64):Int64;

	// Judgement slot API
	/*@:native("allocJudgementSlot")    static function allocJudgementSlot(slot:Int, noteCount:Int64):Void;
	@:native("clearJudgementSlot")    static function clearJudgementSlot(slot:Int):Void;
	@:native("setActiveJudgementSlot") static function setActiveJudgementSlot(slot:Int):Void;
	@:native("getActiveJudgementSlot") static function getActiveJudgementSlot():Int;*/
	@:native("getJudgement")          static function getJudgement(globalIndex:Int64):Bool;
	@:native("setJudgement")          static function setJudgement(globalIndex:Int64, value:Bool):Void;
	//@:native("destroyAllJudgements")  static function destroyAllJudgements():Void;
}
#elseif hl
class File {
	@:hlNative("chart_file", "remap")
	public static function remap(newLength:Int64):Bool { return false; }

	@:hlNative("chart_file", "loadChart")
	public static function loadChart(inFile:String):Void {}

	@:hlNative("chart_file", "getNote")
	public static function getNote(atIndex:hl.I64):MetaNote { return 0; }

	@:hlNative("chart_file", "setNote")
	public static function setNote(atIndex:hl.I64, value:hl.I64):Void {}

	@:hlNative("chart_file", "insertNote")
	public static function insertNote(atGlobalPosition:hl.I64, duration:Int, index:Int, type:Int):Void {}

	@:hlNative("chart_file", "removeNote")
	public static function removeNote(atIndex:hl.I64):Void {}

	@:hlNative("chart_file", "getLength")
	public static function getLength():hl.I64 { return 0; }

	@:hlNative("chart_file", "destroyChart")
	public static function destroyChart():Void {}

	@:hlNative("chart_file", "getTimeCorrectionForIndex")
	public static function getTimeCorrectionForIndex(index:hl.I64):hl.I64 { return 0; }

	// Judgement slot API
	/*@:hlNative("chart_file", "allocJudgementSlot")
	public static function allocJudgementSlot(slot:Int, noteCount:hl.I64):Void {}

	@:hlNative("chart_file", "clearJudgementSlot")
	public static function clearJudgementSlot(slot:Int):Void {}

	@:hlNative("chart_file", "setActiveJudgementSlot")
	public static function setActiveJudgementSlot(slot:Int):Void {}

	@:hlNative("chart_file", "getActiveJudgementSlot")
	public static function getActiveJudgementSlot():Int { return 0; }*/

	@:hlNative("chart_file", "getJudgement")
	public static function getJudgement(globalIndex:hl.I64):Bool { return false; }

	@:hlNative("chart_file", "setJudgement")
	public static function setJudgement(globalIndex:hl.I64, value:Bool):Void {}

	/*@:hlNative("chart_file", "destroyAllJudgements")
	public static function destroyAllJudgements():Void {}*/
}
#end