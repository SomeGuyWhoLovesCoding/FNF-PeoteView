package structures.gameplay;

import lime.media.AudioBuffer;
import lime.media.AudioSource;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;

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

		spectator = Actor.create(parent.view, "spectator", "gf", 250, -100, 24, true);
		spectator.mirror = !spectator.mirror;
		spectator.playAnimation("danceLeft");
		spectator.addToBuffer();

		opponent = Actor.create(parent.view, "opponent", "dad", 250, -100, 24, true);
		opponent.mirror = !opponent.mirror;
		opponent.preComputeSingPosesOfAnimations(singPoses);
		opponent.preComputeMissPosesOfAnimations(missPoses);
		opponent.playAnimation("idle");
		opponent.startingShakeFrame = 0;
		opponent.endingShakeFrame = 1;
		opponent.finishAnim = "idle";
		opponent.addToBuffer();

		player = Actor.create(parent.view, "player", "bfSgwlfnf", 625, 250, 24, true);
		player.preComputeSingPosesOfAnimations(singPoses);
		player.preComputeMissPosesOfAnimations(missPoses);
		player.playAnimation("idle");
		player.startingShakeFrame = 0;
		player.endingShakeFrame = 1;
		player.finishAnim = "idle";
		player.addToBuffer();

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
		var ratio = Math.min(deltaTime * 0.01, 1.0);

		var shake = parent.viewShake;

		view.scroll.x = Tools.lerp(sc.x, targetCamera.x, ratio);
		view.scroll.y = Tools.lerp(sc.y, targetCamera.y, ratio);
		view.shake(shake.x, shake.y);

		for (actor in actors) {
			if (isInGameOver) {
				if (actor != actorOnGameOver) {
					var ratio = (deltaTime * 0.001);
					actor.color.aF = Math.max(actor.color.aF - ratio, 0);
					actor.color.luminanceF = Math.max(actor.color.luminanceF - ratio, 0);
				}
			}
			actor.update(deltaTime);
		}

		var check = !isInGameOver && parent.died;
		#if !FV_LIME_FORK
		check = parent.died;
		if (isInGameOver) {
			updateGameOver(deltaTime);
		} else #end if (check) {
			gameOver();
		}
	}

	function render() {
		for (actor in actors) {
			actor.render();
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

	inline function sing(index:Int, char:Actor, miss:Bool = false, shake:Bool = false, skipAnimation:Bool = false) {
		char.shake = shake;
		if (skipAnimation) return;
		if (miss) {
			char.playAnimationFromMissId(index);
			return;
		}
		char.playAnimationFromSingId(index);
	}

	inline function hitNote(note:MetaNote, timing:Float, notesInOne:Int64) {
		sing(note.index, (note.type == 0 ? opponent : player), false, note.duration > 2 && timing < parent.hitbox * 0.5);

		targetCamera.x = note.type == 0 ? -50 : 50; // Prototype camera logic I have for now
		targetCamera.y = 0;
	}

	inline function missNote(note:MetaNote, notesInOne:Int64) {
		sing(note.index, (note.type == 0 ? opponent : player), true, false);
	}

	inline function completeSustain(note:MetaNote) {
		sing(note.index, (note.type == 0 ? opponent : player), false, false, true);
	}

	inline function releaseSustain(note:MetaNote) {
		sing(note.index, (note.type == 0 ? opponent : player), true, false);
	}

	function dispose() {
		for (actor in actors)
			actor.dispose();

		parent.view.scroll.x = parent.view.scroll.y = 0;
		parent.view.fov = 1.0;

		Main.conductor.onBeat.remove(beatHit);
	}

	// GAME OVER IMPL

	var isInGameOver:Bool;
	var gameOverSound:Int = -1;
	var gameOverMusic:Int = -1;
	var gameOverConfirm:Int = -1;
	var actorOnGameOver:Actor;
    var gameOverConfirmed:Bool;

	function gameOver() {
		_gameover_end_call = (x:Float, y:Float, button:MouseButton) -> {
			endGameOver(button == MouseButton.RIGHT);
		};

		var gameOverMeta = Chart.header.gameOver;
		var theme = gameOverMeta.theme;
		var bpm = gameOverMeta.bpm;

		gameOverMusic = MiniAudio.loadBackgroundTrack('assets/death/fnf_loss_music-${theme}.ogg');

		gameOverSound = MiniAudio.loadSoundEffect('assets/death/fnf_loss_sfx-${theme}.ogg');
		MiniAudio.playSoundEffect(gameOverSound, 0.7);

		gameOverConfirm = MiniAudio.loadSoundEffect('assets/death/fnf_loss_end-${theme}.ogg');

		Main.conductor.reset();
		Main.conductor.changeBpmAt(0, bpm);

		actorOnGameOver.playAnimation("firstDeath");
		actorOnGameOver.finishAnim = "deathLoop";
		actorOnGameOver.shake = false;

		actorOnGameOver.finishCallback = () -> {
			MiniAudio.playBackgroundTrack(gameOverMusic);
			MiniAudio.setBackgroundTrackVolume(gameOverMusic, 0.7);
			MiniAudio.setBackgroundTrackLooping(gameOverMusic, true);
		}

		isInGameOver = true;
	}

	function endGameOver(goBack:Bool = false) {
		MiniAudio.stopBackgroundTrack(gameOverMusic);

		if (goBack) {
			isInGameOver = false;
			Main.switchState(MAIN_MENU);
			return;
		}

		var gameOverMeta = Chart.header.gameOver;
		var theme = gameOverMeta.theme;

		MiniAudio.playSoundEffect(gameOverConfirm, 0.7);

		actorOnGameOver.finishAnim = "";
		actorOnGameOver.playAnimation("deathConfirm");

		Main.current.controls.unBind();
		parent.inputSystem.removeEvents();
		gameOverConfirmed = true;

		haxe.Timer.delay(() -> {
			MiniAudio.stopSoundEffect(gameOverConfirm);
			gameOverConfirm = -1;
			isInGameOver = gameOverConfirmed = false;
			Main.switchState(GAMEPLAY);
			parent.display.show();
		}, 6000); // was 5 sec
	}

	function updateGameOver(deltaTime:Float) {
		Main.current.mouseDown = gameOverConfirmed ? null : _gameover_end_call;

		if (MiniAudio.isBackgroundTrackPlaying(gameOverMusic)) {
			Main.conductor.time += deltaTime;
		}
	}

	// to fix the stupid shit that can't be fixed anywhere else
	var _gameover_end_call:(Float, Float, MouseButton)->Void;
}
