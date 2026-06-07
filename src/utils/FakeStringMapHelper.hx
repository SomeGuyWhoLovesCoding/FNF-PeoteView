package utils;

import haxe.ds.StringMap;

@:publicFields
class FakeStringMapHelper {
    static function fromStringMap<V>(map:StringMap<V>):FakeStringMap<V> {
        var instance = new FakeStringMap<V>();
        for (key in map.keys()) {
            instance.set(key, map.get(key));
        }
        return instance;
    }
}