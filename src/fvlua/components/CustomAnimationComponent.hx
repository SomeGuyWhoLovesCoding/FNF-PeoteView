package fvlua.components;

import sys.FileSystem;
import haxe.ds.StringMap;

using StringTools;

/**
	Animation component instance for Funkin' View.
	@since Development
**/
@:publicFields
class CustomAnimationComponent extends LuaComponentObject {
	#if linc_luajit_funkinview
	public var customActors(default, null):StringMap<Actor>;

	public function new(_parent:FunkinViewLua) {
        super(_parent);

		customActors = new StringMap<Actor>();
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
		vm.addCallback("addCustomActor", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.addToBuffer();
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("playCustomActorAnimation", (actor:Actor, anim:String, loop:Bool = false) -> {
            trace("Custom Actor from lua: ",actor);
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.playAnimation(anim, loop);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("stopCustomActorAnimation", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.stopAnimation();
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("setCustomActorFinishAnim", (actor:Actor, anim:String) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.finishAnim = anim;
			return FunkinViewLua.Function_Continue;
		});

        // these four are here just in case you want to replicate the sing poses of >4 mania
		vm.addCallback("playSingIdCustomActorAnimation", (actor:Actor, index:Int, loop:Bool) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.playAnimationFromSingId(index, loop);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("playMissIdCustomActorAnimation", (actor:Actor, index:Int, loop:Bool) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.playAnimationFromMissId(index, loop);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("preComputeCustomActorSingPoses", (actor:Actor, anims:Array<String>) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.preComputeSingPosesOfAnimations(anims);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("preComputeCustomActorMissPoses", (actor:Actor, anims:Array<String>) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.preComputeMissPosesOfAnimations(anims);
			return FunkinViewLua.Function_Continue;
		});

        // Now for the property get/set
		vm.addCallback("setCustomActorPos", (actor:Actor, x:Float, y:Float) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.x = x;
            actor.y = y;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorPosX", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return 0.0;
			}
			return actor.x;
		});
		vm.addCallback("getCustomActorPosY", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return 0.0;
			}
			return actor.y;
		});
		vm.addCallback("setCustomActorAngle", (actor:Actor, r:Float) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.r = r;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorPosAngle", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return 0.0;
			}
			return actor.r;
		});
		vm.addCallback("setCustomActorFPS", (actor:Actor, fps:Float) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.setFps(fps);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorFPS", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return 0.0;
			}
			return actor.fps;
		});
		vm.addCallback("getCustomActorTag", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return "";
			}
			return actor.tag;
		});
		vm.addCallback("getCustomActorDisplay", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return null;
			}
			return actor.display;
		});
		vm.addCallback("setCustomActorShake", (actor:Actor, shake:Bool) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.shake = shake;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("setCustomActorStartToEndShakeFrames", (actor:Actor, start:Int, end:Int) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return FunkinViewLua.Function_Stop;
			}
			actor.startingShakeFrame = start;
            actor.endingShakeFrame = end;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getCustomActorFrameRange", (actor:Actor) -> {
			if (actor == null) {
				FunkinViewLua.error("Custom Actor cannot be nil!");
				return 1;
			}
			return actor.endingFrameIndex - actor.startingFrameIndex;
		});

        // now ofc we don't want to forget about our pals that access vanilla field characters that are always present in the song no matter what
		vm.addCallback("getPlayer", function():Actor {
			var bf = playField?.field?.player;
			return bf;
		});
		vm.addCallback("getBF", function():Actor { // alt syntax (same api)
			var bf = playField?.field?.player;
            trace("BF: ",bf);
			return bf;
		});
		vm.addCallback("getSpectator", function():Actor {
			var gf = playField?.field?.spectator;
			return gf;
		});
		vm.addCallback("getGF", function():Actor { // alt syntax (same api)
			var gf = playField?.field?.spectator;
			return gf;
		});
		vm.addCallback("getOpponent", function():Actor {
			var opp = playField?.field?.opponent;
			return opp;
		});

        /*// if you want a more object-oriented way of doing things
        // this was when I decided to change all occurrences of `actorName:String` to just be `actor:Actor` because now I've realized about the performance concerns I would've hhad
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
				customActor.dispose();
				customActor = null;
			}
		}
		customActors.clear();
		customActors = null;
	}
	#end
}