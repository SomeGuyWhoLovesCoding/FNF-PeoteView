package fvlua;

import llua.State;
import llua.Lua;
import llua.LuaL;
import llua.Convert;

/**
    A single Lua script instance for Funkin' View.
	@since Development
**/
@:publicFields
class FunkinViewLuaScript {
    #if linc_luajit_funkinview
    public var vm(default, null):State;
    public var disposed(default, null):Bool = false;
    public var path(default, null):String;

    public function new(path:String) {
        this.path = path;
        vm = LuaL.newstate();
        LuaL.openlibs(vm);
        Lua.init_callbacks(vm);
    }

    public function set(variable:String, data:Dynamic) {
        if (vm == null) return;
        Convert.toLua(vm, data);
        Lua.setglobal(vm, variable);
    }

    public function addCallback(callback:String, data:Dynamic) {
        if (vm == null) return;
        Lua_helper.add_callback(vm, callback, data);
    }

    public function dispose() {
        if (disposed) return;
        disposed = true;
        Lua.close(vm);
        vm = null;
    }
    #end
}
