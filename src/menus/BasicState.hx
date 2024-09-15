package menus;

import lime.ui.KeyCode;

/**
 * The basic state.
 */
#if !debug
@:noDebug
#end
class BasicState extends State {
	var logo:Sprite;
	var logo2:Sprite;
	var logo3:Sprite;

	/**
	 * The gameplay camera.
	 */
	var dispGP:Display;
	var prgmGP:Program;
	var buffGP:Buffer<Sprite>;

	/**
	 * The interface camera.
	 */
	var dispUI:Display;
	var prgmUI:Program;
	var buffUI:Buffer<Sprite>;

	/**
	 * The sounds.
	 */
	var inst:Audio;

	override function new() {
		super();

		buffGP = new Buffer<Sprite>(100, 100, true);
		buffUI = new Buffer<Sprite>(100, 100, true);

		prgmGP = new Program(buffGP);
		prgmUI = new Program(buffUI);

		dispGP = new Display(0, 0, Screen.view.width, Screen.view.height, 0xFF000044);
		dispUI = new Display(0, 0, Screen.view.width, Screen.view.height, 0x0FF00F44);

		Screen.view.addDisplay(dispGP);
		Screen.view.addDisplay(dispUI);

		dispGP.addProgram(prgmGP);
		dispUI.addProgram(prgmUI);

		TextureSystem.createMultiTexture("tex0", ["assets/test0.png", "assets/test1.png", "assets/test2.png", "assets/test3.png", "assets/suzanneRGBA.png"]);
		TextureSystem.setTexture(prgmGP, "tex0", "custom");

		logo = new Sprite(50, 50);
		logo.w = 400;
		logo.h = 300;
		buffGP.addElement(logo);

		logo2 = new Sprite(200, 50);
		logo2.c = 0x0000ffff;
		buffUI.addElement(logo2);

		logo3 = new Sprite(400, 150);
		logo3.c = 0x00ff00ff;
		logo3.w = 150;
		logo3.h = 160;
		buffUI.addElement(logo3);

		inst = new Audio("assets/silver-doom.opus");
	}

	var time:Float = 0;
	override function updateState(deltaTime:Int) {
		inst.update();

		logo.r += deltaTime * 0.075;
		time += deltaTime / 500;
		logo3.x = Math.sin(time) * 300 + 300;

		logo2.x = (inst.time * 2.0) % (1280 - logo2.w);

		buffGP.update();
		buffUI.update();
	}

	override function onKeyDown(keyCode, keyModifier) {
		//trace(keyCode);

		if (keyCode == KeyCode.RETURN)
		{
			inst.play();
		}

		if (keyCode == KeyCode.SPACE)
		{
			inst.pause();
		}

		if (keyCode == KeyCode.A)
		{
			inst.time -= 1000;
		}

		if (keyCode == KeyCode.D)
		{
			inst.time += 1000;
		}

		if (keyCode == KeyCode.B)
		{
			inst.time = 1000000;
		}

		if (keyCode == KeyCode.MINUS) {
			inst.speed -= 0.1;
		}

		if (keyCode == KeyCode.PLUS) {
			inst.speed += 0.1;
		}

		if (keyCode == KeyCode.BACKSPACE)
		{
			inst.stop();
		}

		if (keyCode == KeyCode.NUMBER_1)
		{
			logo.slot++;
		}

		if (keyCode == KeyCode.NUMBER_2)
		{
			logo2.slot++;
		}

		if (keyCode == KeyCode.NUMBER_3)
		{
			logo3.slot++;
		}
	}
}