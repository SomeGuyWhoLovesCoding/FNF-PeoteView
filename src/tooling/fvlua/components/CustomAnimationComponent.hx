package tooling.fvlua.components;

import sys.FileSystem;

using StringTools;

/**
	Animation component instance for Funkin' View.
	@since 0.94
**/
@:publicFields
class CustomAnimationComponent extends LuaComponentObject {
	#if linc_luajit_funkinview
	inline static var GLOBAL_BF = "FV_BF_099";
	inline static var GLOBAL_GF = "FV_GF_099";
	inline static var GLOBAL_OP = "FV_OP_099";

	public var customActors(default, null):FakeStringMap<Actor>;

	public function new(_parent:FunkinViewLua) {
		super(_parent);

		customActors = new FakeStringMap<Actor>();
	}

	// functions are a placeholder.
	override public function addCallbacksList(vm:FunkinViewLuaScript) {
		// API from Actor class
		vm.addCallback("customActorNew", (actorName:String, toDisplay:String, actorType:String, actorChar:String, x:Int, y:Int, fps:Int) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var displayValue = toDisplay.toLowerCase();
			var display = Reflect.field(playField, toDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + toDisplay.toLowerCase());
				return FunkinViewLua.Function_Stop;
			}
			customActors.set(actorName, Actor.create(display, actorType, actorChar, x, y, fps, true));
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("addCustomActor", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			customActors.get(actorName).addToBuffer();
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("playCustomActorAnimation", (actorName:String, anim:String, loop:Bool = false) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.playAnimation(anim, loop);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("stopCustomActorAnimation", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.stopAnimation();
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("setCustomActorFinishAnim", (actorName:String, anim:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.finishAnim = anim;
			return FunkinViewLua.Function_Continue;
		});

		// these four are here just in case you want to replicate the sing poses of >4 mania
		vm.addCallback("playSingIdCustomActorAnimation", (actorName:String, index:Int, loop:Bool) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.playAnimationFromSingId(index, loop);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("playMissIdCustomActorAnimation", (actorName:String, index:Int, loop:Bool) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.playAnimationFromMissId(index, loop);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("preComputeCustomActorSingPoses", (actorName:String, anims:Array<String>) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.preComputeSingPosesOfAnimations(anims);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("preComputeCustomActorMissPoses", (actorName:String, anims:Array<String>) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.preComputeMissPosesOfAnimations(anims);
			return FunkinViewLua.Function_Continue;
		});

		// Now for the property get/set
		vm.addCallback("setCustomActorPos", (actorName:String, x:Float, y:Float) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.x = x;
			customActor.y = y;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorPosX", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return 0.0;
			}
			var customActor = customActors.get(actorName);
			return customActor.x;
		});
		vm.addCallback("getCustomActorPosY", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return 0.0;
			}
			var customActor = customActors.get(actorName);
			return customActor.y;
		});
		vm.addCallback("setCustomActorAngle", (actorName:String, r:Float) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.r = r;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorPosAngle", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return 0.0;
			}
			var customActor = customActors.get(actorName);
			return customActor.r;
		});
		vm.addCallback("setCustomActorFPS", (actorName:String, fps:Float) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.setFps(fps);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorFPS", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return 0.0;
			}
			var customActor = customActors.get(actorName);
			return customActor.fps;
		});
		vm.addCallback("getCustomActorTag", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return "";
			}
			var customActor = customActors.get(actorName);
			return customActor.tag;
		});
		vm.addCallback("getCustomActorDisplay", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return null;
			}
			var customActor = customActors.get(actorName);
			return customActor.display;
		});
		vm.addCallback("setCustomActorShake", (actorName:String, shake:Bool) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.shake = shake;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("setCustomActorStartToEndShakeFrames", (actorName:String, start:Int, end:Int) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var customActor = customActors.get(actorName);
			customActor.startingShakeFrame = start;
			customActor.endingShakeFrame = end;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorFrameRange", (actorName:String) -> {
			if (actorName == "" || actorName == null) {
				FunkinViewLua.error("Custom Actor's Key cannot be empty or nil!");
				return 1;
			}
			var customActor = customActors.get(actorName);
			return customActor.endingFrameIndex - customActor.startingFrameIndex;
		});

		// now ofc we don't want to forget about our pals that access vanilla field characters that are always present in the song no matter what
		vm.addCallback("getPlayer", function() {
			var bf = playField?.field?.player;
			if (!customActors.exists(GLOBAL_BF)) {
				customActors.set(GLOBAL_BF, bf);
			}
			return GLOBAL_BF;
		});
		vm.addCallback("getBF", function() { // alt syntax (same api)
			var bf = playField?.field?.player;
			if (!customActors.exists(GLOBAL_BF)) {
				customActors.set(GLOBAL_BF, bf);
			}
			return GLOBAL_BF;
		});
		vm.addCallback("getSpectator", function() {
			var gf = playField?.field?.spectator;
			if (!customActors.exists(GLOBAL_GF)) {
				customActors.set(GLOBAL_GF, gf);
			}
			return GLOBAL_GF;
		});
		vm.addCallback("getGF", function() {
			var gf = playField?.field?.spectator;
			if (!customActors.exists(GLOBAL_GF)) {
				customActors.set(GLOBAL_GF, gf);
			}
			return GLOBAL_GF;
		});
		vm.addCallback("getOpponent", function() {
			var opp = playField?.field?.opponent;
			if (!customActors.exists(GLOBAL_OP)) {
				customActors.set(GLOBAL_OP, opp);
			}
			return GLOBAL_OP;
		});

		/*// if you want a more object-oriented way of doing things
			vm.addCallback("playCustomAnimOfActorObject", function(actor:Actor, anim:String) {
				if (actor == null) {
					FunkinViewLua.error("Field Actor's cannot be nil!");
					return FunkinViewLua.Function_Stop;
				}
				actor.playAnimation(anim, loop);
				return FunkinViewLua.Function_Continue;
		});*/
	}

	override public function dispose() {
		super.dispose();

		for (customActor in customActors) {
			if (customActor != null) {
				// they will all dispose naturally since playfield's going to be disposed
				if (customActors.get(GLOBAL_BF) != customActor
					&& customActors.get(GLOBAL_GF) != customActor
					&& customActors.get(GLOBAL_OP) != customActor)
					customActor.dispose();
				customActor = null;
			}
		}
		customActors.clear();
		customActors = null;
	}
	#end
}
