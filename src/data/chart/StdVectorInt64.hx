package data.chart;

// Edited version of this: https://community.haxe.org/t/passing-a-string-array-from-haxe-to-c/1794/4

#if cpp
import cpp.RawPointer;
import cpp.Pointer;

@:keep
@:unreflective
@:structAccess
@:include('vector')
@:native('std::vector<int64_t>')
extern class StdVectorInt64
{
    @:native('std::vector<int64_t>')
    static function create() : StdVectorInt64;

    @:runtime inline static function fromInt64Array(arr:Array<Int64>):StdVectorInt64 {
        return untyped __cpp__('std::vector<int64_t>({0}, {0} + {1})', Pointer.ofArray(arr).raw, arr.length);
    }

    function push_back(i:Int64) : Void;

    function data() : RawPointer<Int64>;

    function size() : Int;
}
#end