package structures.gameplay;

import lime.media.AudioBuffer;
import lime.media.AudioSource;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	The field of the gameplay state.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
	It is responsible for managing the actors in the game, such as the player, opponent, and spectator.
	It also handles the game over logic and camera movement.
	@since Development
**/
@:publicFields
class Field {
	var actors:Array<Actor>;

	var spectator(get, set):Actor;

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
		var view = parent.view;

		var sc = view.scroll;
		var ratio = deltaTime * 0.01;

		var shake = parent.viewShake;

		view.scroll.x = sc.x + ratio * (targetCamera.x - sc.x);
		view.scroll.y = sc.y + ratio * (targetCamera.y - sc.y);
		view.shake(shake.x, shake.y);

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
				if (@:privateAccess gameOverMusic.__backend.playing) {
					Main.conductor.time = gameOverMusic.currentTime;
				}

				if (gameOverMusic.currentTime == gameOverMusic.length) {
					endGameOver();
				}
			}
	
			if (gameOverConfirm != null) {
				if (gameOverConfirm.currentTime == gameOverConfirm.length) {
					gameOverConfirm = null;
					isInGameOver = false;
					Main.switchState(GAMEPLAY);
					parent.display.show();
				}
			}
		} else if (parent.died) {
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

	function hitNote(note:MetaNote, timing:Int) {
		sing(note.index, (note.lane == 0 ? opponent : player), false, note.duration > 12 && timing < parent.hitbox * 0.5);

		targetCamera.x = note.lane == 0 ? -50 : 50; // Prototype camera logic I have for now
	}

	function missNote(note:MetaNote) {
		sing(note.index, (note.lane == 0 ? opponent : player), true, false);
	}

	function completeSustain(note:MetaNote) {
		sing(note.index, (note.lane == 0 ? opponent : player), false, false, true);
	}

	function releaseSustain(note:MetaNote) {
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
	static var gameOverSounds:Map<String, Map<String, AudioSource>> = [];
	var gameOverSound:AudioSource;
	var gameOverMusic:AudioSource;
	var gameOverConfirm:AudioSource;
	var actorOnGameOver:Actor;

	function gameOver() {
		removeCallbacks();

		var gameOverMeta = parent.chart.header.gameOver;
		var theme = gameOverMeta.theme;
		var bpm = gameOverMeta.bpm;

		if (!gameOverSounds.exists(theme)) {
			gameOverSounds[theme] = new Map<String, AudioSource>();
		}

		if (!gameOverSounds[theme].exists("firstDeath")) {
			gameOverSounds[theme]["firstDeath"] = new AudioSource(AudioBuffer.fromFile('assets/death/fnf_loss_sfx-${theme}.ogg'));
		}

		gameOverSound = gameOverSounds[theme]["firstDeath"];
		gameOverSound.play();

		if (!gameOverSounds[theme].exists("deathMusic")) {
			gameOverSounds[theme]["deathMusic"] = new AudioSource(AudioBuffer.fromFile('assets/death/fnf_loss_music-${theme}.ogg'));
		}

		gameOverMusic = gameOverSounds[theme]["deathMusic"];

		Main.conductor.reset();
		Main.conductor.changeBpmAt(0, bpm);

		actorOnGameOver.finishAnim = "deathLoop";
		actorOnGameOver.shake = false;
		actorOnGameOver.playAnimation("firstDeath");

		actorOnGameOver.finishCallback = gameOverMusic.play;

		isInGameOver = true;
	}

	function endGameOver(goBack:Bool = false) {
		if (gameOverMusic != null) {
			gameOverMusic.stop();
			gameOverMusic = null;
		}

		if (goBack) {
			Main.switchState(MAIN_MENU);
			return;
		}

		var gameOverMeta = parent.chart.header.gameOver;
		var theme = gameOverMeta.theme;

		if (!gameOverSounds[theme].exists("confirm")) {
			gameOverSounds[theme]["confirm"] = new AudioSource(AudioBuffer.fromFile('assets/death/fnf_loss_end-${theme}.ogg'));
		}

		gameOverConfirm = gameOverSounds[theme]["confirm"];
		gameOverConfirm.play();

		actorOnGameOver.finishAnim = "";
		actorOnGameOver.playAnimation("deathConfirm");

		Main.current.controls.unBind();
		parent.inputSystem.removeEvents();
	}
}