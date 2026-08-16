package tooling.fvlua;

import sys.FileSystem;
import llua.State;
import llua.Lua;
import llua.LuaL;
import llua.Convert;
import haxe.ds.Vector;
import haxe.Int64;
import rhythm.NoteFormulaResult;

using StringTools;

// ------------------------------------------------------------------
// Main Lua / Movement System
// ------------------------------------------------------------------
@:publicFields
class FunkinViewLua {
	#if linc_luajit_funkinview
	var vms(default, null):Array<FunkinViewLuaScript>;
	var disposed(default, null):Bool;

	static inline var Function_Stop = "##FUNKINVIEWLUA_FUNCTION_STOP";
	static inline var Function_Continue = "##FUNKINVIEWLUA_FUNCTION_CONTINUE";
	static inline var Function_StopLua = "##FUNKINVIEWLUA_FUNCTION_STOPLUA";

	var parent(default, null):PlayField;
	var components(default, null):Array<LuaComponentObject>;

	public function new(parent:PlayField, path:String, header:Header) {
		this.parent = parent;
		disposed = false;

		var files = sys.FileSystem.readDirectory(path);
		vms = [];
		components = [];

		components.push(new CustomLuaSpriteComponent(this));
		components.push(new CustomPlayFieldComponent(this));
		components.push(new CustomAnimationComponent(this));
		components.push(new CustomNoteUtilsComponent(this));

		var luaFilesFound = 0;
		for (i in 0...files.length) {
			var scriptFile = '$path/${files[i]}';
			if (!scriptFile.endsWith(".lua"))
				continue;
			Sys.println('Lua File Found : $scriptFile');
			if (initScript(scriptFile) == null)
				continue;
			luaFilesFound++;
		}

		var stageLuaFile = '${path.split("/")[0]}/stages/${header.stage}.lua';
		if (FileSystem.exists(stageLuaFile))
			initScript(stageLuaFile);

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
		for (component in components)
			component.addCallbacksList(script);
		vms.push(script);
		return script;
	}

	function addCallbacksList(luaScript:FunkinViewLuaScript) {
		luaScript.addCallback("trace", function(string:String) Sys.println('FunkinViewLua: $string'));
		luaScript.set('buildTarget', lime.system.System.platformName);
	}

	function updateVariablesList() {
		for (script in vms)
			for (component in components)
				component.updateVariablesList(script);
	}

	static function typeToString(type:Int):String {
		switch (type) {
			case Lua.LUA_TBOOLEAN:
				return "boolean";
			case Lua.LUA_TNUMBER:
				return "number";
			case Lua.LUA_TSTRING:
				return "string";
			case Lua.LUA_TTABLE:
				return "table";
			case Lua.LUA_TFUNCTION:
				return "function";
		}
		if (type <= Lua.LUA_TNIL)
			return "nil";
		return "unknown";
	}

	// --- Note Movement Formula System (Bytecode) ---
	private var noteMovementInterp:NoteMovementInterp = null;
	private var noteMovementSource:String = null;
	private var noteMovementLoaded:Bool = false;

	public function setNoteFormulaSource(source:String) {
		if (noteMovementSource == source)
			return;
		noteMovementSource = source;
		noteMovementInterp = new NoteMovementInterp(noteMovementSource);
		noteMovementLoaded = false;
	}

	public function resetNoteFormulaSource() {
		noteMovementInterp = null;
		noteMovementSource = null;
		noteMovementLoaded = false;
	}

	function ensureNoteMovementInterp():Bool {
		if (noteMovementSource == null)
			return false;
		if (noteMovementLoaded && noteMovementInterp != null)
			return true;

		try {
			noteMovementInterp = new NoteMovementInterp(noteMovementSource);
			noteMovementLoaded = true;
			return true;
		} catch (e:Dynamic) {
			error('Note movement formula compile error: $e');
			return false;
		}
	}

	private var noteMovementResult:NoteFormulaResult = new NoteFormulaResult();

	public function callNoteFormula(diff:Float, scrollSpeed:Float, receptorX:Float, receptorY:Float, index:Float, type:Float):NoteFormulaResult {
		if (!ensureNoteMovementInterp())
			return null;
		return noteMovementInterp.run(diff, scrollSpeed, receptorX, receptorY, index, type, noteMovementResult);
	}

	// --- Standard Lua Function Calls ---
	private static var NO_ARGS(default, null):Array<Dynamic> = [];

	private var returns(default, null):Array<Dynamic> = [];

	public function callFunction(fname:String, args:haxe.Rest<Dynamic>):Array<Dynamic> {
		returns.resize(0);
		if (vms == null)
			return null;
		for (script in vms) {
			var lua:State = script.vm;

			if (disposed)
				return [Function_Continue];

			try {
				if (lua == null) {
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

				//BOTTLENECK: mid args.toArray() allocates a fresh Array copy on every script dispatch of every callback that receives args (incl. per-frame update calls) | FIX: iterate the Rest directly (Rest IS an Array) and skip the copy
				var argsArr:Array<Any> = args == null ? NO_ARGS : args.toArray();
				for (arg in argsArr)
					Convert.toLua(lua, arg);
				var status:Int = Lua.pcall(lua, argsArr.length, 1, 0);

				if (status != Lua.LUA_OK) {
					var errorMessage:String = getErrorMessage(lua, status);
					error(errorMessage + "(at " + fname + ")");
					returns.push(Function_Continue);
					continue;
				}

				var result:Dynamic = cast Convert.fromLua(lua, -1);
				if (result == null)
					result = Function_Continue;

				Lua.pop(lua, 1);
				returns.push(result);
				continue;
			} catch (e:Dynamic) {
				trace(e);
			}
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
			return switch (status) {
				case Lua.LUA_ERRRUN: "Runtime Error";
				case Lua.LUA_ERRMEM: "Memory Allocation Error";
				case Lua.LUA_ERRERR: "Critical Error";
				case Lua.LUA_ERRSYNTAX: "Syntax Error";
				default: "Unknown Error";
			}
		}

		var v:String = Lua.tostring(lua, -1);
		Lua.pop(lua, 1);

		if (v != null)
			v = v.trim();
		if (v == null || v == "") {
			return switch (status) {
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
		if (colorSwatch == null)
			return Color.WHITE;
		return colorSwatch;
	}

	inline public static function capitalize(text:String):String
		return text.charAt(0).toUpperCase() + text.substr(1).toLowerCase();

	public function dispose() {
		disposed = true;

		resetNoteFormulaSource();

		for (component in components)
			component.dispose();
		components.resize(0);
		components = null;
		for (script in vms)
			script.dispose();

		vms.resize(0);
		vms = null;
	}
	#end
}
