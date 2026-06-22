package fvlua.components;

import sys.FileSystem;

using StringTools;

/**
	A Playfield component instance for Funkin' View.
	@since 0.94
**/
@:publicFields
class CustomPlayFieldComponent extends LuaComponentObject {
	#if linc_luajit_funkinview
	public function new(_parent:FunkinViewLua) {
		super(_parent);
	}

	override public function addCallbacksList(vm:FunkinViewLuaScript):Void {
		vm.set('Function_StopLua', FunkinViewLua.Function_StopLua);
		vm.set('Function_Continue', FunkinViewLua.Function_Continue);
		vm.set('Function_Stop', FunkinViewLua.Function_Stop);

		vm.set('version', MainMenu.fnfpVer);
		vm.set('modFolder', Paths.customAssetPath);

		vm.set('curBpm', Chart.header.bpm);
		vm.set('bpm', Main.conductor.bpm);
		vm.set('scrollSpeed', playField.scrollSpeed);
		vm.set('crochet', Main.conductor.crochet);
		vm.set('stepCrochet', Main.conductor.stepCrochet);
		vm.set('measureCrochet', Main.conductor.measureCrochet);
		vm.set('songLength', Mixer.length);
		vm.set('songName', playField.formatCustomSongName(Chart.header.title));
		vm.set('loadedSongName', Chart.header.title);
		vm.set('chartPath', Chart.header.dir);
		vm.set('startedCountdown', playField.startedCountdown);
		vm.set('loadedStage', Chart.header.stage);
		vm.set('curStage', playField.formatCustomStage(Chart.header.stage));
		vm.addCallback("setStage", (stage:String) -> {
			if (stage == "" || stage == null) {
				FunkinViewLua.error("Stage name cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			playField.setCustomStage(stage);

			return FunkinViewLua.Function_Continue;
		});

		// WIP, for story mode
		/*set('isStoryMode', PlayState.isStoryMode);
		set('difficulty', PlayState.storyDifficulty);

		set('difficultyName', Difficulty.getString(false));
		set('difficultyPath', Difficulty.getFilePath());
		set('difficultyNameTranslation', Difficulty.getString(true));
		set('weekRaw', PlayState.storyWeek);
		set('week', WeekData.weeksList[PlayState.storyWeek]);
		set('seenCutscene', PlayState.seenCutscene);
		set('hasVocals', PlayState.SONG.needsVoices);*/

		// regular old bullshit from psych engine
		vm.addCallback("getProperty", (name:String) -> {
			return Reflect.getProperty(playField, name);
		});
		vm.addCallback("setProperty", (name:String, value:Dynamic) -> {
			return Reflect.setProperty(playField, name, value);
		});

		// for field camera stuff
		// now you can customize it however you like it
		vm.addCallback("turnOnCustomCamera", function() {
			playField.field.turnoncustomcamera = true;
		});
		vm.addCallback("turnOffCustomCamera", function() {
			playField.field.turnoncustomcamera = false;
		});
		vm.addCallback("setDefaultCameraPosition", (lane:Int, x:Float, y:Float) -> {
			var field = playField.field;
			if (field == null) return;
			field.defaultCameraXpos[lane] = x;
			field.defaultCameraYpos[lane] = y;
		});

		// because why not
		vm.addCallback("loadSong", (songDir:String) -> {
			Main.songChosen = songDir;
			Main.switchState(GAMEPLAY);
		});

		// .
		vm.addCallback("triggerEvent", function(name:String, values:Array<String>) {
			//trace('Triggered event: ' + name + ', ' + value1 + ', ' + value2);
			return true;
		}); // this one specifically is a wip.
		var exitSongCallback = function() {
			playField.pause(false);
			Tools.forSync(() -> {
				Main.uponSongExit();
			});
			return true;
		};
		vm.addCallback("endSong", exitSongCallback);
		vm.addCallback("exitSong", exitSongCallback);
		vm.addCallback("restartSong", function(skipTransition:Bool = false) {
			// this is the only way that this would work without literally crashing the game.
			// The one-frame delay just doesn't matter to any casual player.
			// the same thing goes to above
			playField.pause(false);
			Tools.forSync(() -> {
				Main.switchState(GAMEPLAY, skipTransition);
			});
			return true;
		});
		vm.addCallback("setSongPosition", (time:Float) -> {
			var pf = playField; // FunkinViewLua.playField : PlayField
			if (pf == null || pf.disposed || !pf.songStarted || pf.songEnded || pf.paused || pf.died) return;
			pf.setTime(time);
		});

		vm.addCallback("setCameraScroll", function(x:Float, y:Float) {
			playField.field.targetCamera.x = x;
			playField.field.targetCamera.y = y;
		});
		vm.addCallback("setCameraFollowPoint", function(x:Float, y:Float) {
			playField.view.scroll.x = x;
			playField.view.scroll.x = y;
		});
		vm.addCallback("addCameraScroll", function(x:Float = 0, y:Float = 0) {
			playField.field.targetCamera.x += x;
			playField.field.targetCamera.y += y;
		});
		vm.addCallback("addCameraFollowPoint", function(x:Float = 0, y:Float = 0) {
			playField.view.scroll.x += x;
			playField.view.scroll.y += y;
		});
		vm.addCallback("getCameraScrollX", () -> playField.field.targetCamera.x);
		vm.addCallback("getCameraScrollY", () -> playField.field.targetCamera.y);
		vm.addCallback("getCameraFollowX", () -> playField.view.scroll.x);
		vm.addCallback("getCameraFollowY", () -> playField.view.scroll.y);

		vm.addCallback("setCameraShake", function(camera:String, x:Float, y:Float) {
			var shake = playField.viewShake;
			shake.x = x;
			shake.y = y;
			
		vm.addCallback("setCameraShake", (fromDisplay:String, x:Float, y:Float) -> {
			var display = Reflect.field(playField, fromDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + fromDisplay.toLowerCase());
				return FunkinViewLua.Function_Stop;
			}
			var shake:Point = null;
			switch (fromDisplay.toLowerCase()) {
				case "view":
					shake = playField.viewShake;
				case "display":
					shake = playField.dispShake;
				default:
			}
			shake.x = x;
			shake.y = y;
			return FunkinViewLua.Function_Continue;
		});
		});

		vm.addCallback('addScore', function(value:Int) {
			playField.score += value;
		});
		vm.addCallback('addMisses', function(value:Int) {
			playField.misses += value;
		});
		vm.addCallback('addCombo', function(value:Int) {
			playField.combo += value;
		});
		vm.addCallback('resetCombo', function(value:Int) {
			playField.combo = 0;
		});
		vm.addCallback('addDeath', function() {
			playField.deathCounter++;
		});
		vm.addCallback('addZoom', function(fromDisplay:String, value:Float) {
			var display = Reflect.field(playField, fromDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + fromDisplay.toLowerCase());
			}
			display.fov += value;
		});

		vm.addCallback('getAccuracyString', playField.accuracy.toString);

		vm.addCallback('healthGainMult', function(lane) {
			return playField.healthGain[lane];
		});
		vm.addCallback('healthLossMult', function(lane) {
			return playField.healthLoss[lane];
		});

		vm.addCallback('setHealthGainMult', function(lane, value) {
			playField.healthGain[lane] = value;
			vm.addCallback('healthGainMult', function(lane) {
				return playField.healthGain[lane];
			});
		});
		vm.addCallback('setHealthLossMult', function(lane, value) {
			playField.healthLoss[lane] = value;
			vm.addCallback('healthLossMult', function(lane) {
				return playField.healthLoss[lane];
			});
		});

		vm.addCallback('setPlaybackRate', function(speed:Float) {
			// this is here because lua is not safe with this game when setting certain properties
			Mixer.speed = speed;
		});

		vm.addCallback('setHealth', function(health:Float) {
			playField.health = health;
		});

		vm.addCallback('turnOnCustomHealthBarColor', function() {
			if (playField.hud == null) return;
			if (playField.hud.healthBar == null) return;
			playField.hud.healthBar.customHealthBarColorEnabled = true;
		});

		vm.addCallback('turnOffCustomHealthBarColor', function() {
			if (playField.hud == null) return;
			if (playField.hud.healthBar == null) return;
			playField.hud.healthBar.customHealthBarColorEnabled = false;
		});

		vm.addCallback('setHealthBarColorsLeft', function(left:Array<String>) {
			if (playField.hud == null) return;
			if (playField.hud.healthBar == null) return;
			var colorArray:Array<Color> = Tools.hexesToOpaqueColor(left);
			playField.hud.healthBar.healthIconColors[0] = Tools.convertToSixColors(colorArray);
		});

		vm.addCallback('setHealthBarColorsRight', function(right:Array<String>) {
			if (playField.hud == null) return;
			if (playField.hud.healthBar == null) return;
			var colorArray:Array<Color> = Tools.hexesToOpaqueColor(right);
			playField.hud.healthBar.healthIconColors[1] = Tools.convertToSixColors(colorArray);
		});

		// note movement callbacks

		/*vm.addCallback('setCustomNoteMovementVar', function(name:String, value:Float) {
			if (playField.noteSystem == null) return;
			playField.noteSystem.customVariables.set(name, value);
		});

		vm.addCallback('getCustomNoteMovementVar', function(name:String) {
			if (playField.noteSystem == null) return;
			return playField.noteSystem.customVariables.get(name);
		});*/

		vm.addCallback('setCustomNoteMoveFormula', function(script:String) {
			if (script == null) {
				FunkinViewLua.error("Script cannot be nil. Use `resetCustomNoteMoveFormula` instead.");
				return FunkinViewLua.Function_Stop;
			}
			parent.setNoteFormulaSource(script);
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('resetCustomNoteMoveFormula', function() {
			parent.resetNoteFormulaSource();
			return FunkinViewLua.Function_Continue;
		});
	}

	override public function updateVariablesList(vm:FunkinViewLuaScript):Void {
		// Screen stuff
		vm.set('screenWidth', Main.VARIABLE_WIDTH);
		vm.set('screenHeight', Main.VARIABLE_HEIGHT);

		// Other settings
		vm.set('downscroll', SaveData.state.preferences.downScroll);
		vm.set('frameRate', SaveData.state.graphics.frameRate);
		vm.set('hideHud', SaveData.state.preferences.hideHUD);
		vm.set('smoothHealthbar', SaveData.state.preferences.smoothHealthbar);
		vm.set('scoreZoom', SaveData.state.preferences.scoreTxtBopping);
		vm.set('cameraZoomOnBeat', SaveData.state.preferences.cameraZooming);
		vm.set('currentModDirectory', Paths.customAssetPath);

		vm.set('playbackRate', Mixer.speed);

		vm.set("songPosition", playField.songPosition);
		vm.set('totalNotesHit', playField.accuracy.left);
		vm.set('totalPlayed', playField.accuracy.right);

		vm.set('curMeasure', Main.conductor.curMeasure);
		vm.set('curBeat', Main.conductor.curBeat);
		vm.set('curStep', Main.conductor.curStep);

		vm.set('score', Tools.int64ToFloat(playField.score));
		vm.set('misses', Tools.int64ToFloat(playField.misses));
		vm.set('combo', Tools.int64ToFloat(playField.combo));
		vm.set('deaths', playField.deathCounter);

		vm.set('inGameOver', playField.field?.isInGameOver);

		vm.set('botPlay', playField.botplay);
		vm.set('practice', playField.practiceMode);

		vm.set('health', playField.health);
	}

	override public function dispose():Void {
		// any cleanup
		super.dispose();
	}
	#end
}