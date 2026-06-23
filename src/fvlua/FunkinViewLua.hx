package fvlua;

import sys.FileSystem;
import llua.State;
import llua.Lua;
import llua.LuaL;
import llua.Convert;
using StringTools;

/**
	Lua system of Funkin' View.
	@since Development
**/
@:publicFields
class FunkinViewLua {
	#if linc_luajit_funkinview
	var vms(default, null):Array<FunkinViewLuaScript>;
	var disposed(default, null):Bool;

	//// THE VARIABLES ////
	static inline var Function_Stop = "##FUNKINVIEWLUA_FUNCTION_STOP";
	static inline var Function_Continue = "##FUNKINVIEWLUA_FUNCTION_CONTINUE";
	static inline var Function_StopLua = "##FUNKINVIEWLUA_FUNCTION_STOPLUA";

	var parent(default, null):PlayField;
	var components(default, null):Array<LuaComponentObject>;

	public function new(parent:PlayField, path:String, header:Header) {
		this.parent = parent;
		disposed = false;

		var files = sys.FileSystem.readDirectory(path);
		//Sys.println('Lua files? $files');

		vms = [];
		components = [];

		components.push(new CustomLuaSpriteComponent(this));
		components.push(new CustomPlayFieldComponent(this));
		components.push(new CustomAnimationComponent(this));

		var luaFilesFound = 0;
		for (i in 0...files.length) {
			var scriptFile = '$path/${files[i]}';
			if (!scriptFile.endsWith(".lua")) continue;
			Sys.println('Lua File Found : $scriptFile');
			if (initScript(scriptFile) == null) continue;
			luaFilesFound++;
		}

		var stageLuaFile = '${path.split("/")[0]}/stages/${header.stage}.lua';
		if (FileSystem.exists(stageLuaFile)) initScript(stageLuaFile);

		callFunction('create', null);
	}

	function initScript(scriptFile:String):FunkinViewLuaScript {
		var script = new FunkinViewLuaScript(scriptFile);
		var loadStatus = LuaL.dofile(script.vm, scriptFile);
		if (loadStatus != Lua.LUA_OK) {
			var error = getErrorMessage(script.vm, loadStatus);
			Sys.println('Lua load error in $scriptFile: $error');
			script.dispose();
			return null;
		}
		addCallbacksList(script);
		for (component in components) component.addCallbacksList(script);
		vms.push(script);
		return script;
	}

	function addCallbacksList(luaScript:FunkinViewLuaScript) {
		luaScript.addCallback("trace", function(string:String) Sys.println('FunkinViewLua: $string'));

		// build target (windows, mac, linux, etc.)
		luaScript.set('buildTarget', lime.system.System.platformName);
	}

	function updateVariablesList() {
		for (script in vms)
			for (component in components)
				component.updateVariablesList(script);
	}

	static function typeToString(type:Int):String {
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

	private var noteFormulaVM:State = null;
	private var noteFormulaSource:String = null;
	private var noteFormulaLoaded:Bool = false;

	function setNoteFormulaSource(source:String) {
		if (noteFormulaSource == source) return;
		noteFormulaSource = source;
		noteFormulaLoaded = false;
	}

	function resetNoteFormulaSource() {
		Lua.close(noteFormulaVM);
		noteFormulaVM = null;
		noteFormulaSource = null;
		noteFormulaLoaded = false;
	}

	function ensureNoteFormulaVM():Bool {
		if (noteFormulaSource == null) return false;

		if (noteFormulaVM == null) {
			noteFormulaVM = LuaL.newstate();
			LuaL.openlibs(noteFormulaVM);
			Lua.init_callbacks(noteFormulaVM);
		}
		
		if (noteFormulaLoaded) return true;
		if (noteFormulaSource == null) return false;
		
		var status:Int = LuaL.loadstring(noteFormulaVM, noteFormulaSource);
		if (status != Lua.LUA_OK) {
			error(getErrorMessage(noteFormulaVM, status) + " (loading noteFormula string)");
			return false;
		}
		
		status = Lua.pcall(noteFormulaVM, 0, 0, 0);
		if (status != Lua.LUA_OK) {
			error(getErrorMessage(noteFormulaVM, status) + " (running noteFormula string)");
			return false;
		}
		
		noteFormulaLoaded = true;
		return true;
	}

	private var noteFormulaResult:NoteFormulaResult = new NoteFormulaResult();

	function callNoteFormula(diff:Float, scrollSpeed:Float, receptorX:Float, receptorY:Float, index:Float, type:Float):NoteFormulaResult {
		if (!ensureNoteFormulaVM()) {
			noteFormulaResult.x = 0;
			noteFormulaResult.y = 0;
			noteFormulaResult.scale = 1;
			noteFormulaResult.sustainRot = 0;
			noteFormulaResult.scrollMultiplier = 1;
			return null;
		}
		
		var lua:State = noteFormulaVM;
		
		Lua.getglobal(lua, "noteFormula");
		if (Lua.type(lua, -1) != Lua.LUA_TFUNCTION) {
			Lua.pop(lua, 1);
			noteFormulaResult.x = 0;
			noteFormulaResult.y = 0;
			noteFormulaResult.scale = 1;
			noteFormulaResult.sustainRot = 0;
			noteFormulaResult.scrollMultiplier = 1;
			return null;
		}
		
		Lua.pushnumber(lua, diff);
		Lua.pushnumber(lua, scrollSpeed);
		Lua.pushnumber(lua, receptorX);
		Lua.pushnumber(lua, receptorY);
		Lua.pushnumber(lua, index);
		Lua.pushnumber(lua, type);

		var status:Int = Lua.pcall(lua, 6, 5, 0);

		if (status != Lua.LUA_OK) {
			error(getErrorMessage(lua, status) + " (noteFormula)");
			noteFormulaResult.x = 0;
			noteFormulaResult.y = 0;
			noteFormulaResult.scale = 1;
			noteFormulaResult.sustainRot = 0;
			noteFormulaResult.scrollMultiplier = 1;
			return null;
		}
    
		// If any return is nil, cancel
		if (Lua.type(lua, -5) == Lua.LUA_TNIL ||
			Lua.type(lua, -4) == Lua.LUA_TNIL ||
			Lua.type(lua, -3) == Lua.LUA_TNIL ||
			Lua.type(lua, -2) == Lua.LUA_TNIL ||
			Lua.type(lua, -1) == Lua.LUA_TNIL) {
			Lua.pop(lua, 4);
			return null;
		}
		
		if (Lua.type(lua, -5) == Lua.LUA_TNUMBER) noteFormulaResult.x = Lua.tonumber(lua, -5);
		else noteFormulaResult.x = 0;
		if (Lua.type(lua, -4) == Lua.LUA_TNUMBER) noteFormulaResult.y = Lua.tonumber(lua, -4);
		else noteFormulaResult.y = 0;
		if (Lua.type(lua, -3) == Lua.LUA_TNUMBER) noteFormulaResult.scale = Lua.tonumber(lua, -3);
		else noteFormulaResult.scale = 1;
		if (Lua.type(lua, -2) == Lua.LUA_TNUMBER) noteFormulaResult.sustainRot = Lua.tonumber(lua, -2);
		else noteFormulaResult.sustainRot = 0;
		if (Lua.type(lua, -1) == Lua.LUA_TNUMBER) noteFormulaResult.scrollMultiplier = Lua.tonumber(lua, -1);
		else noteFormulaResult.scrollMultiplier = 0;
		
		Lua.pop(lua, 5);
		return noteFormulaResult;
	}

	private static var NO_ARGS(default, null):Array<Dynamic> = [];
	private var returns(default, null):Array<Dynamic> = [];
	function callFunction(fname:String, args:haxe.Rest<Dynamic>):Array<Dynamic> {
		returns.resize(0);
		if (vms == null) return null;
		for (script in vms) {
			var lua:State = script.vm;

			// this is a direct port from psych.
			if(disposed) return [Function_Continue];

			try {
				if(lua == null) {
					returns.push(Function_Continue);
					continue;
				}

				Lua.getglobal(lua, fname);
				var type:Int = Lua.type(lua, -1);

				if (type != Lua.LUA_TFUNCTION) {
					if (type > Lua.LUA_TNIL) {
						error("attempt to call a " + typeToString(type) + " value at " + fname);
					}

					Lua.pop(lua, 1);
					returns.push(Function_Continue);
					continue;
				}

				var argsArr:Array<Any> = args == null ? NO_ARGS : args.toArray();
				for (arg in argsArr) Convert.toLua(lua, arg);
				var status:Int = Lua.pcall(lua, argsArr.length, 1, 0);

				// Checks if it's not successful, then show a error.
				if (status != Lua.LUA_OK) {
					var errorMessage:String = getErrorMessage(lua, status);
					error(errorMessage + "(at " + fname + ")");
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
			/*catch (e:Dynamic) {
				trace(e);
			}*/
			returns.push(Function_Continue);
			continue;
		}
		return returns;
	}

	static dynamic function error(err:String) {
		trace('[ERROR] FunkinViewLua: $err');
	}

	function getErrorMessage(lua:State, status:Int):String {
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

	static function colorFromStringUtil(color:String):Color {
		var defaultColorString = capitalize(color.toLowerCase());
		if (Color.defaultMap.exists(defaultColorString)) {
			return Color.defaultMap[defaultColorString];
		}

		var colorSwatch:Null<Int> = Std.parseInt(color);
		if (colorSwatch == null) return Color.WHITE;
		return colorSwatch;
	}

	// https://github.com/ShadowMario/FNF-PsychEngine/blob/5c67ced49e5a98535298a6daa3f8f4ec79ac8399/source/backend/CoolUtil.hx#L41
	inline public static function capitalize(text:String)
		return text.charAt(0).toUpperCase() + text.substr(1).toLowerCase();

	function dispose() {
		disposed = true;
    
		// Clean up note formula VM
		if (noteFormulaVM != null) {
			Lua.close(noteFormulaVM);
			noteFormulaVM = null;
		}
		noteFormulaSource = null;
		noteFormulaLoaded = false;

		for (component in components) component.dispose();
		components.resize(0);
		components = null;
		for (script in vms) script.dispose();
		
		vms.resize(0);
		vms = null;
	}
	#end
}

@:publicFields
@:structInit
class NoteFormulaResult {
	var x:Float = 0;
	var y:Float = 0;
	var scale:Float = 1;
	var sustainRot:Float = 0;
	var scrollMultiplier:Float = 1;

	function new() {}
}