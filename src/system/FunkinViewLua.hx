package system;

using StringTools;

#if linc_luajit_funkinview
/**
    A single Lua script instance for Funkin' View.
**/
@:publicFields
class FunkinViewLuaScript {
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
		if(vm == null) {
			return;
		}

		Convert.toLua(vm, data);
		Lua.setglobal(vm, variable);
	}

    public function addCallback(callback:String, data:Dynamic) {
        if (vm == null) {
            return;
        }

        Lua_helper.add_callback(vm, callback, data);
    }

    public function dispose() {
        if (disposed) return;
        disposed = true;
        Lua.close(vm);
        vm = null;
    }
}
#end

/**
    Lua system of Funkin' View.
**/
@:publicFields
class FunkinViewLua {
    #if linc_luajit_funkinview
    private var vms(default, null):Array<FunkinViewLuaScript>;
    var disposed(default, null):Bool;

    //// THE VARIABLES ////
    private static inline var Function_Stop = "##FUNKINVIEWLUA_FUNCTION_STOP";
    private static inline var Function_Continue = "##FUNKINVIEWLUA_FUNCTION_CONTINUE";
    private static inline var Function_StopLua = "##FUNKINVIEWLUA_FUNCTION_STOPLUA";

    function new(path:String) {
        disposed = false;

        var files = sys.FileSystem.readDirectory(path);
        //Sys.println('Lua files? $files');

        vms = [];

        var luaFilesFound = 0;
        for (i in 0...files.length) {
            var scriptFile = '$path/${files[i]}';
            if (!scriptFile.endsWith(".lua")) continue;
            Sys.println('Lua File? $scriptFile');
            var script = new FunkinViewLuaScript(scriptFile);
            var loadStatus = LuaL.dofile(script.vm, scriptFile);
            if (loadStatus != Lua.LUA_OK) {
                var error = getErrorMessage(script.vm, loadStatus);
                Sys.println('Lua load error in $scriptFile: $error');
                script.dispose();
                continue;
            }
            addCallbacksList(script);
            vms.push(script);
            luaFilesFound++;
        }
    }

    function addCallbacksList(luaScript:FunkinViewLuaScript) {
        luaScript.addCallback("trace", function(string:String) Sys.println('FunkinViewLua: $string'));
    }

    public static function typeToString(type:Int):String {
        switch(type) {
            case Lua.LUA_TBOOLEAN: return "boolean";
            case Lua.LUA_TNUMBER: return "number";
            case Lua.LUA_TSTRING: return "string";
            case Lua.LUA_TTABLE: return "table";
            case Lua.LUA_TFUNCTION: return "function";
        }
        if (type <= Lua.LUA_TNIL) return "nil";
        return "unknown";
    }

    public var lastCalledFunction:String = '';
    private var NO_ARGS(default, null):Array<Dynamic> = [];
    function callFunction(fname:String, args:haxe.Rest<Dynamic>):Dynamic {
        for (script in vms) {
            var lua = script.vm;

            // this is a direct port from psych as a test.
            if(disposed) return Function_Continue;

            lastCalledFunction = fname;
            try {
                if(lua == null) return Function_Continue;

                Lua.getglobal(lua, fname);
                var type:Int = Lua.type(lua, -1);

                if (type != Lua.LUA_TFUNCTION) {
                    if (type > Lua.LUA_TNIL) {
                        trace("ERROR (" + fname + "): attempt to call a " + typeToString(type) + " value");
                    }

                    Lua.pop(lua, 1);
                    return Function_Continue;
                }

                var argsArr = args != null ? args.toArray() : NO_ARGS;
                for (arg in argsArr) Convert.toLua(lua, arg);
                var status:Int = Lua.pcall(lua, argsArr.length, 1, 0);

                // Checks if it's not successful, then show a error.
                if (status != Lua.LUA_OK) {
                    var error:String = getErrorMessage(lua, status);
                    trace("ERROR (" + fname + "): " + error);
                    return Function_Continue;
                }

                // If successful, pass and then return the result.
                var result:Dynamic = cast Convert.fromLua(lua, -1);
                if (result == null) result = Function_Continue;

                Lua.pop(lua, 1);
                return result;
            }
            catch (e:Dynamic) {
                trace(e);
            }
            return Function_Continue;
        }
        return Function_Continue;
    }

    public function getErrorMessage(lua:State, status:Int):String {
        if (Lua.gettop(lua) == 0) {
            return switch(status) {
                case Lua.LUA_ERRRUN: "Runtime Error";
                case Lua.LUA_ERRMEM: "Memory Allocation Error";
                case Lua.LUA_ERRERR: "Critical Error";
                case Lua.LUA_ERRSYNTAX: "Syntax Error";
                default: "Unknown Error";
            }
        }

        var v:String = Lua.tostring(lua, -1);
        Lua.pop(lua, 1);

        if (v != null) v = v.trim();
        if (v == null || v == "") {
            return switch(status) {
                case Lua.LUA_ERRRUN: "Runtime Error";
                case Lua.LUA_ERRMEM: "Memory Allocation Error";
                case Lua.LUA_ERRERR: "Critical Error";
                case Lua.LUA_ERRSYNTAX: "Syntax Error";
                default: "Unknown Error";
            }
        }

        return v;
    }

    function dispose() {
        disposed = true;
        for (script in vms) script.dispose();
        vms.resize(0);
        vms = null;
    }
    #end
}