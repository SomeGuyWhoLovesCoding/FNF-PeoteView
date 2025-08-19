package custom.haxe;

/**
 * This map implementation was made because you can't initialize a normal `haxe.ds.Map<MetaNote, V>` on the hashlink target.
 */
@:generic
abstract MetaNoteMap<T>(Map<MetaNote, T>) {
	/**
		Creates a new MetaNoteMap.
	**/
	inline public function new():Void {
        this = new Map<MetaNote, T>();
    };

	/**
		See `Map.set`
	**/
	public function set(key:MetaNote, value:T):Void {
        this.set(key, value);
    };

	/**
		See `Map.get`
	**/
	public function get(key:MetaNote):Null<T> {
        return this.get(key);
    };

	/**
		See `Map.exists`
	**/
	public function exists(key:MetaNote):Bool {
        return this.exists(key);
    };

	/**
		See `Map.remove`
	**/
	public function remove(key:MetaNote):Bool {
        return this.remove(key);
    };

	/**
		See `Map.toString`
	**/
	public function toString():String {
        return this.toString();
    };

	/**
		See `Map.clear`
	**/
	public function clear():Void {
        this.clear();
    };
}