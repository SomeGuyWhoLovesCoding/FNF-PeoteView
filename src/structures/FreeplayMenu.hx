package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The freeplay submenu.
	This is where you can select the song you want to play.
	And this is the menu with the alphabet text that appears on the screen which scrolls by the mouse or the up or down key.
	It is responsible for rendering the freeplay menu and updating it based on the player's input.
	@since Development
**/
@:publicFields
class FreeplayMenu {
	//////////////////////// MAIN ////////////////////////

	static var display(default, null):CustomDisplay;

	var active(default, null):Bool;
	var opened(default, null):Bool;

	var freeplayScreen(default, null):FreeplayScreen;

	var nav(default, null):Navigation = new Navigation();

	//////////////////////// SCROLL (LIKE PHONE) ////////////////////////
	var isDragging:Bool = false;
	var dragStartY:Float = 0.0;
	var lastDragY:Float = 0.0;
	var dragAccum:Float = 0.0;

	// fling impl
	var dragVelocity:Float = 0.0;
	var lastDragTime:Float = 0.0;

	private static inline var DRAG_THRESHOLD:Float = 1.0; // pixels per nav tick

	//////////////////////// THE REST ////////////////////////
	var actions(default, null):ActionMap;

	function new() {
		freeplayScreen = new FreeplayScreen(this, 'chapter1');

		// Pre-warm all addPrograms so the first open() is instant.
		freeplayScreen.preWarm();

		actions = [
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_BACK => { action: back },
			Controls.Action.UI_ACCEPT => { action: enter },
			// Todo: move chapters
			Controls.Action.UI_LEFT => { action: cast function (isDown:Bool, param:Int) {
				//reload('chapter1');
			 } },
			Controls.Action.UI_RIGHT => { action: cast function (isDown:Bool, param:Int) {
				//reload('chapter1');
			 } }
		];
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;
	}

	function render(deltaTime:Float) {
		if (!isDragging && Math.abs(dragVelocity) > 0.01) {
			freeplayScreen.curSelectedTarget += (dragVelocity * deltaTime) / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT));
			freeplayScreen.curSelectedTarget = Math.max(0, Math.min(freeplayScreen.songsAvailable.length - 1, freeplayScreen.curSelectedTarget));
			nav.setTo(Math.round(freeplayScreen.curSelectedTarget));

			dragVelocity *= Math.pow(0.92, deltaTime * 0.04); // exponential decay
			if (Math.abs(dragVelocity) < 0.01) dragVelocity = 0.0;
		}

		freeplayScreen.render(deltaTime);
	}

	function open() {
		Main.current.popupFreeplayMenu();

		opened = active = true;

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);

			Main.current.mouseDown = mousePress;
			window.onMouseUp.add(mouseRelease);
			window.onMouseMove.add(mouseDrag);
			window.onMouseWheel.add(mouseWheel);
		}, 1);

		if (freeplayScreen.disposed) {
			freeplayScreen.reload(freeplayScreen.chapter);
		}
		freeplayScreen.addPrograms();
	}

	function reload(newChapter:String) {
		nav.reset();
		freeplayScreen.reload(newChapter);
	}

	function close() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		Main.current.mouseDown = null;
		window.onMouseUp.remove(mouseRelease);
		window.onMouseMove.remove(mouseDrag);
		window.onMouseWheel.remove(mouseWheel);

		opened = false;

		haxe.Timer.delay(function() {
			var mm = Main.current.mainMenu;
			if (mm != null) {
				MainMenu.selectedAlpha = 1.0;
				mm.addEvents();
			}
		}, 1);
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();
		Main.current.playCancelSound();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		nav.scroll(1);
		nav.resetIfOver(freeplayScreen.songsAvailable.length);
		Main.current.playScrollSound();
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		nav.scroll(-1);
		nav.resetIfUnder(freeplayScreen.songsAvailable.length - 1);
		Main.current.playScrollSound();
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
		Main.songChosen = freeplayScreen.songsAvailable[nav.value()].dir;
		Main.switchState(GAMEPLAY);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		switch (button) {
			case LEFT:
				isDragging = true;
				dragStartY = y;
				lastDragY = y;
				dragAccum = 0.0;
				dragVelocity = 0.0;
				lastDragTime = haxe.Timer.stamp();
				freeplayScreen.curSelectedTarget = freeplayScreen.curSelectedLerp;
				//Main.current.playScrollSound();
			case RIGHT:
				back(true, 0);
			default:
		}
	}

	function mouseRelease(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button != LEFT) return;

		if (isDragging && Math.abs(dragStartY - y) < 4.0) {
			enter(true, 0);
		}

		isDragging = false;
		dragAccum = 0.0;
		// velocity carries over into render
	}

	function mouseDrag(x:Float, y:Float) {
		if (!isDragging) return;

		var delta = lastDragY - y;
		lastDragY = y;

		var now = haxe.Timer.stamp();
		var dt = now - lastDragTime;
		lastDragTime = now;

		var _delta = (delta / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)));

		if (dt > 0) dragVelocity = _delta / 3;

		freeplayScreen.curSelectedTarget += _delta;
		freeplayScreen.curSelectedTarget = Math.max(0, Math.min(freeplayScreen.songsAvailable.length - 1, freeplayScreen.curSelectedTarget));
		nav.setTo(Math.round(freeplayScreen.curSelectedTarget));
	}

	function mouseWheel(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		nav.scroll(-Math.floor(y));
		nav.resetIfBoth(freeplayScreen.songsAvailable.length, freeplayScreen.songsAvailable.length - 1);
		Main.current.playScrollSound();
	}

	function shutDown() {
		freeplayScreen.shutDown();

		active = false;
		Main.current.removeFreeplayMenu();
	}

	function dispose() {
		close();
		freeplayScreen.unload();

		active = false;
		Main.current.removeFreeplayMenu();
	}
}