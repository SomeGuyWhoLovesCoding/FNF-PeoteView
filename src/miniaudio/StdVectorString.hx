package miniaudio;

// Edited version of this: https://community.haxe.org/t/passing-a-string-array-from-haxe-to-c/1794/4
#if cpp
import cpp.RawPointer;
import cpp.ConstCharStar;

@:keep
@:unreflective
@:structAccess
@:include('vector')
@:native('std::vector<const char*>')
extern class StdVectorString {
	@:native('std::vector<const char*>')
	static function create():StdVectorString;

	@:runtime inline static function fromStringArray(arr:Array<String>):StdVectorString {
		var vec = StdVectorString.create();
		for (s in arr) {
			vec.push_back(ConstCharStar.fromString(s));
		}
		return vec;
	}

	function push_back(_string:ConstCharStar):Void;

	function data():RawPointer<ConstCharStar>;

	function size():Int;
}
#end
