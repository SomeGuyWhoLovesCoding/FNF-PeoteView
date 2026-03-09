package fvlua;

using StringTools;

/**
    Lua system of Funkin' View.
**/
@:publicFields
class FunkinViewLua {
    #if linc_luajit_funkinview
    var vms(default, null):Array<FunkinViewLuaScript>;
    var disposed(default, null):Bool;

    //// THE VARIABLES ////
    private static inline var Function_Stop = "##FUNKINVIEWLUA_FUNCTION_STOP";
    private static inline var Function_Continue = "##FUNKINVIEWLUA_FUNCTION_CONTINUE";
    private static inline var Function_StopLua = "##FUNKINVIEWLUA_FUNCTION_STOPLUA";

    var parent(default, null):PlayField;
    var customSpriteComponent(default, null):CustomLuaSpriteComponent;

    public function new(parent:PlayField, path:String) {
        this.parent = parent;
        disposed = false;

        var files = sys.FileSystem.readDirectory(path);
        //Sys.println('Lua files? $files');

        vms = [];

        customSpriteComponent = new CustomLuaSpriteComponent(this);

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
            customSpriteComponent.addCallbacksList(script);
            vms.push(script);
            luaFilesFound++;
        }
    }

    function addCallbacksList(luaScript:FunkinViewLuaScript) {
        callFunction('create', null);
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
    private var NO_ARGS(default, null):Array<Any> = [];
    private var returns(default, null):Array<Any> = [];
    function callFunction(fname:String, args:haxe.Rest<Any>):Array<Any> {
        returns.resize(0);
        if (vms == null) return null;
        for (script in vms) {
            var lua = script.vm;

            // this is a direct port from psych as a test.
            if(disposed) return [Function_Continue];

            lastCalledFunction = fname;
            try {
                if(lua == null) {
                    returns.push(Function_Continue);
                    continue;
                }

                Lua.getglobal(lua, fname);
                var type:Int = Lua.type(lua, -1);

                if (type != Lua.LUA_TFUNCTION) {
                    if (type > Lua.LUA_TNIL) {
                        trace("ERROR (" + fname + "): attempt to call a " + typeToString(type) + " value");
                    }

                    Lua.pop(lua, 1);
                    returns.push(Function_Continue);
                    continue;
                }

                var argsArr = args != null ? args.toArray() : NO_ARGS;
                for (arg in argsArr) Convert.toLua(lua, arg);
                var status:Int = Lua.pcall(lua, argsArr.length, 1, 0);

                // Checks if it's not successful, then show a error.
                if (status != Lua.LUA_OK) {
                    var error:String = getErrorMessage(lua, status);
                    trace("ERROR (" + fname + "): " + error);
                    returns.push(Function_Continue);
                    continue;
                }

                // If successful, pass and then return the result.
                var result:Dynamic = cast Convert.fromLua(lua, -1);
                if (result == null) result = Function_Continue;

                Lua.pop(lua, 1);
                returns.push(result);
                continue;
            }
            catch (e:Dynamic) {
                trace(e);
            }
            returns.push(Function_Continue);
            continue;
        }
        return returns;
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
        customSpriteComponent.dispose();
        for (script in vms) script.dispose();
        vms.resize(0);
        vms = null;
    }
    #end
}