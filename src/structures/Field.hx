package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	The field of the gameplay state.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
**/
@:publicFields
class Field {
	var actors:Array<Actor>;

	var spectator(get, set):Actor;
	var actions(default, null):ActionMap;

	inline function get_spectator() {
		return actors[0];
	}

	inline function set_spectator(actor:Actor) {
		return actors[0] = actor;
	}

	var opponent(get, set):Actor;

	inline function get_opponent() {
		return actors[1];
	}

	inline function set_opponent(actor:Actor) {
		return actors[1] = actor;
	}

	var player(get, set):Actor;

	inline function get_player() {
		return actors[2];
	}

	inline function set_player(actor:Actor) {
		return actors[2] = actor;
	}

	var numSpectators:Int = 1;
	var parent:PlayField;

	static var singPoses:Array<String> = ["singLEFT", "singDOWN", "singUP", "singRIGHT"];
	static var missPoses:Array<String> = ["singLEFTmiss", "singDOWNmiss", "singUPmiss", "singRIGHTmiss"];

	function new(parent:PlayField) {
		this.parent = parent;

		actors = [];
		actors.resize(3);

		spectator = new Actor(parent.view, "gf", 250, -100, 24);
		spectator.mirror = !spectator.mirror;
		spectator.playAnimation("danceLeft");
		spectator.addToBuffer();

		opponent = new Actor(parent.view, "dad", 250, -100, 24);
		opponent.mirror = !opponent.mirror;
		opponent.playAnimation("idle");
		opponent.startingShakeFrame = 0;
		opponent.endingShakeFrame = 1;
		opponent.finishAnim = "idle";
		opponent.addToBuffer();

		player = new Actor(parent.view, "bf", 625, 250, 24);
		player.playAnimation("idle");
		player.startingShakeFrame = 0;
		player.endingShakeFrame = 1;
		player.finishAnim = "idle";
		player.addToBuffer();

		addCallbacks();

		Main.conductor.onBeat.add(beatHit);

		parent.view.scroll.y = -100;
		targetCamera.x = 0;
		targetCamera.y = 0;

		actions = [
			Controls.Action.UI_ACCEPT => { action: accept },
			Controls.Action.UI_BACK => { action: back },
			Controls.Action.GAME_RESET => { action: reset },
		];
	}

	function beatHit(beat:Float) {
		if (isInGameOver) {
			if (beat > 0) {
				actorOnGameOver.playAnimation("deathLoop");
			}
			return;
		}

		var beatIsEven = beat % 2 == 0;
		if (!opponent.animationRunning && beatIsEven) opponent.playAnimation("idle");
		if (!player.animationRunning && beatIsEven) player.playAnimation("idle");
		spectator.playAnimation(beatIsEven ? "danceLeft" : "danceRight");
	}

	var targetCamera:Point = {x: 0, y: 0};

	function update(deltaTime:Float) {
		var sc = parent.view.scroll;
		var ratio = deltaTime * 0.01;

		parent.view.scroll.x = sc.x + ratio * (targetCamera.x - sc.x);
		parent.view.scroll.y = sc.y + ratio * (targetCamera.y - sc.y);

		for (actor in actors) {
			if (isInGameOver) {
				if (actor != actorOnGameOver) {
					actor.c.aF = Tools.lerp(actor.c.aF, 0, ratio * 0.75);
				}
			}
			actor.update(deltaTime);
		}

		if (isInGameOver) {
			if (gameOverMusic != null) {
				if (gameOverMusic.playing) {
					gameOverMusic.update();
					Main.conductor.time = gameOverMusic.time;
				}
				if (gameOverMusic.finished) {
					accept(true, 0);
				}
			}
	
			if (gameOverConfirm != null) {
				if (gameOverConfirm.finished) {
					gameOverConfirm = null;
					isInGameOver = false;
					Main.switchState(GAMEPLAY);
					parent.display.show();
				}
			}
			return;
		}

		if (!isInGameOver && parent.died) {
			gameOver();
		}
	}

	function resetCharacters() {
		spectator.shake = false;
		spectator.playAnimation("danceLeft");

		opponent.shake = false;
		opponent.playAnimation("idle");

		player.shake = false;
		player.playAnimation("idle");
	}

	function sing(index:Int, char:Actor, miss:Bool = false, shake:Bool = false, skipAnimation:Bool = false) {
		var poses = (miss ? missPoses : singPoses);
		if (!skipAnimation) char.playAnimation(poses[index % poses.length]);
		char.shake = shake;
	}

	inline function hitNote(note:MetaNote, timing:Int) {
		sing(note.index, (note.lane == 0 ? opponent : player), false, note.duration > 12 && timing < parent.hitbox * 0.5);

		targetCamera.x = note.lane == 0 ? -50 : 50; // Prototype camera logic I have for now
	}

	inline function missNote(note:MetaNote) {
		sing(note.index, (note.lane == 0 ? opponent : player), true, false);
	}

	inline function completeSustain(note:MetaNote) {
		sing(note.index, (note.lane == 0 ? opponent : player), false, false, true);
	}

	inline function releaseSustain(note:MetaNote) {
		sing(note.index, (note.lane == 0 ? opponent : player), true, false);
	}

	function addCallbacks() {
		parent.onNoteHit.add(hitNote);
		parent.onNoteMiss.add(missNote);
		parent.onSustainComplete.add(completeSustain);
		parent.onSustainRelease.add(releaseSustain);
	}

	function removeCallbacks() {
		parent.onNoteHit.remove(hitNote);
		parent.onNoteMiss.remove(missNote);
		parent.onSustainComplete.remove(completeSustain);
		parent.onSustainRelease.remove(releaseSustain);
	}

	function dispose() {
		removeCallbacks();

		for (actor in actors)
			actor.dispose();

		parent.view.scroll.x = parent.view.scroll.y = 0;
		parent.view.fov = 1.0;

		Main.conductor.onBeat.remove(beatHit);
	}

	// GAME OVER IMPL

	var isInGameOver:Bool;
	static var gameOverSounds:Map<String, Map<String, Sound>> = [];
	var gameOverSound:Sound;
	var gameOverMusic:Sound;
	var gameOverConfirm:Sound;
	var actorOnGameOver:Actor;

	function gameOver() {
		removeCallbacks();

		var gameOverMeta = parent.chart.header.gameOver;
		var theme = gameOverMeta.theme;
		var bpm = gameOverMeta.bpm;

		if (!gameOverSounds.exists(theme)) {
			gameOverSounds[theme] = new Map<String, Sound>();
		}

		if (!gameOverSounds[theme].exists("firstDeath")) {
			var snd = gameOverSounds[theme]["firstDeath"] = new Sound();
			snd.fromFile('assets/death/fnf_loss_sfx-${theme}.flac');
		}

		gameOverSound = gameOverSounds[theme]["firstDeath"];
		gameOverSound.play();

		if (!gameOverSounds[theme].exists("deathMusic")) {
			var music = gameOverSounds[theme]["deathMusic"] = new Sound();
			music.fromFile('assets/death/fnf_loss_music-${theme}.flac');
		}

		gameOverMusic = gameOverSounds[theme]["deathMusic"];
		gameOverMusic.time = 0;

		Main.conductor.reset();
		Main.conductor.changeBpmAt(0, bpm);

		actorOnGameOver.finishAnim = "deathLoop";
		actorOnGameOver.shake = false;
		actorOnGameOver.playAnimation("firstDeath");

		actorOnGameOver.finishCallback = gameOverMusic.play;
		
		Main.current.controls.bindTo(actions);

		isInGameOver = true;
	}

	function accept(isDown:Bool, param:Int) {
		if (!isDown) return;

		if (gameOverMusic != null) {
			gameOverMusic.stop();
			gameOverMusic = null;
		}

		var gameOverMeta = parent.chart.header.gameOver;
		var theme = gameOverMeta.theme;

		if (!gameOverSounds[theme].exists("confirm")) {
			var conf = gameOverSounds[theme]["confirm"] = new Sound();
			conf.fromFile('assets/death/fnf_loss_end-${theme}.flac');
		}

		gameOverConfirm = gameOverSounds[theme]["confirm"];
		gameOverConfirm.play();

		actorOnGameOver.finishAnim = "";
		actorOnGameOver.playAnimation("deathConfirm");

		Main.current.controls.unBind();
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		Main.switchState(MAIN_MENU);
	}

	function reset(isDown:Bool, param:Int) {
		if (!isDown) return;
		gameOver();
	}
}