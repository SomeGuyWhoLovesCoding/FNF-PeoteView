package fvlua.components;

/**
	Base class for Lua callback component objects attached to a FunkinViewLua instance.
	@since 0.94
**/
class LuaComponentObject {
	public var parent(default, null):FunkinViewLua;
	public var playField(default, null):PlayField;

	public function new(parent:FunkinViewLua) {
		this.parent = parent;
		this.playField = parent.parent;
	}

	public function addCallbacksList(vm:FunkinViewLuaScript):Void {}

	public function dispose():Void {
		parent = null;
		playField = null;
	}
}