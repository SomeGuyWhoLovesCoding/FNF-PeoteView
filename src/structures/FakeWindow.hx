package structures;

import peote.view.element.Elem;
import lime.ui.MouseButton;

/**
	The custom window for Funkin' View.
	This is a simple window that is only meant to have a colored title bar with custom title test, dragged with, and not having extra features such as split screen logic.
**/
@:publicFields
@:access(lime._internal.backend.native.NativeCFFI)
class FakeWindow {
	final windowOffset:Vector<Int> = Vector.fromData([-1, -8]);

	// Internal stuff
	var display:Display;
	var windowBuffer:Buffer<Elem>;
	var windowProgram:Program;
	var iconBuffer:Buffer<Elem>;
	var iconProgram:Program;
	var closeButtonBuffer:Buffer<CloseButton>;
	var closeButtonProgram:Program;

	// Elements and properties
	var border:Vector<Elem>;
	var borderColor(default, set):Color = 0x444444FF;
	inline function set_borderColor(color:Color) {
		for (i in 0...border.length) {
			var part = border[i];
			part.c = color;
			windowBuffer.updateElement(part);
		}
		return borderColor = color;
	}

	var titleBar:Elem;
	var titleBarColor(default, set):Color = Color.LIME;
	inline function set_titleBarColor(color:Color) {
		titleBar.c = color;
		windowBuffer.updateElement(titleBar);
		return titleBarColor = color;
	}

	var closeButton:CloseButton;
	var closeButtonClicked:CloseButton;

	var icon:Elem;
	var iconTexture(default, set):String;
	inline function set_iconTexture(value:String) {
		TextureSystem.disposeTexture("windowIcon");
		TextureSystem.createTexture("windowIcon", value);
		return value;
	}

	var text:Text;
	var titleTextFont(default, set):String = "arial";
	inline function set_titleTextFont(value:String) {
		text.scale = 1;
		text.font = value;
		text.scale = (icon.h - 3) / text.height;
		text.y = Math.round((titleBar.h - (text.height * text.scale)) * 0.5);
		return titleTextFont = value;
	}

	var visible(default, set):Bool = true;

	inline function set_visible(value:Bool) {
		return visible = display.isVisible = value;
	}

	function isMouseInsideApp() {
		var peoteView = Main.current.peoteView;
		return mousePos.x >= 1 && mousePos.x <= peoteView.width + 1 &&
			mousePos.y >= 29 && mousePos.y <= peoteView.height + 29;
	}

	function isMouseAtCloseButton() {
		var peoteView = Main.current.peoteView;
		return mousePos.x >= closeButton.x && mousePos.x <= closeButton.x + closeButton.w - 1 &&
			mousePos.y >= closeButton.y && mousePos.y <= closeButton.y + closeButton.h;
	}

	function new(peoteView:PeoteView) {
		display = new Display(0, 0, peoteView.width, peoteView.height, 0x00000000);

		windowBuffer = new Buffer<Elem>(5);
		windowProgram = new Program(windowBuffer);
		display.addProgram(windowProgram);

		var window = lime.app.Application.current.window;

		titleBar = new Elem(1, 1, display.width - 2, 30, 0, 0, 0, 0, titleBarColor);
		windowBuffer.addElement(titleBar);

		border = new Vector<Elem>(4);
		for (i in 0...border.length) {
			border[i] = new Elem(0, 0, 0, 0, 0, 0, 0, 0, borderColor);
			windowBuffer.addElement(border[i]);
		}

		iconTexture = "assets/test0.png";

		iconBuffer = new Buffer<Elem>(1);
		iconProgram = new Program(iconBuffer);
		TextureSystem.setTexture(iconProgram, "windowIcon", "windowIcon");
		display.addProgram(iconProgram);

		icon = new Elem(titleBar.x + 8, titleBar.y + 6, titleBar.h - 12, titleBar.h - 12, 0, 0, 0, 0, 0xFFFFFFFF);
		iconBuffer.addElement(icon);

		text = new Text("windowText", titleBar.x + (icon.x + icon.w) + 4, titleBar.y, display, "Funkin' View", titleTextFont);
		text.scale = (icon.h - 3) / text.height;
		text.y = titleBar.y + Math.round((titleBar.h - (text.height * text.scale)) * 0.5);
		text.color = 0x000000FF;

		closeButtonBuffer = new Buffer<CloseButton>(2);
		closeButtonProgram = new Program(closeButtonBuffer);
		TextureSystem.createTiledTexture("windowCloseButton", "assets/window/close-button.png", 2, 1, true);
		TextureSystem.setTexture(closeButtonProgram, "windowCloseButton", "windowCloseButton");
		display.addProgram(closeButtonProgram);

		closeButton = new CloseButton(titleBar.w - 44, 1, 45, 30, 0);
		closeButtonBuffer.addElement(closeButton);

		closeButtonClicked = new CloseButton(titleBar.w - 44, 1, 45, 30, 1);
		closeButtonClicked.c.aF = 0;
		closeButtonClicked.tile = 1;
		closeButtonBuffer.addElement(closeButtonClicked);

		var peoteView = Main.current.peoteView;

		peoteView.addDisplay(display);

		window.onMouseMove.add(drag);
		window.onMouseDown.add(mouseDown);
		window.onMouseUp.add(mouseUp);

		centerWindow();
	}

	public function centerWindow() {
		var window = lime.app.Application.current.window;

		window.x = Math.floor(window.width * 0.25) + windowOffset[0];
		window.y = (Math.floor(window.height * 0.25) - 30) + windowOffset[1];
	}

	var initMousePos:Point = {x: 0, y: 0};
	var mousePos:Point = {x: 0, y: 0};
	var windowMousePos:Point = {x: 0, y: 0};
	var _isDragging:Bool = false;

	function drag(x:Float, y:Float) {
		var window = lime.app.Application.current.window;

		mousePos.x = x;
		mousePos.y = y;
	}

	var isMouseDown:Bool;

	function mouseDown(x:Float, y:Float, mouseButton:MouseButton) {
		isMouseDown = !isMouseAtCloseButton();

		if (_isDragging) return;

		if ((x >= titleBar.x && x <= titleBar.x + titleBar.w) &&
			(y >= titleBar.y && y <= titleBar.y + titleBar.h) &&
			mouseButton == LEFT && !isMouseAtCloseButton()) {
			_isDragging = true;

			var window = lime.app.Application.current.window;

			initMousePos.x = x;
			initMousePos.y = y;
		}
	}

	function mouseUp(x:Float, y:Float, mouseButton:MouseButton) {
		if (isMouseAtCloseButton() && !isMouseDown) Sys.exit(0);

		isMouseDown = false;

		if (!_isDragging) return;

		if (mouseButton == LEFT) {
			_isDragging = false;
		}
	}

	function updateCloseButton(deltaTime:Float) {
		var isHoveringCloseButton = isMouseAtCloseButton() && !isMouseDown;

		closeButtonClicked.c.aF = isHoveringCloseButton ? 1.0 : 0.0;
		closeButtonBuffer.updateElement(closeButtonClicked);

		if (!_isDragging) return;

		var windowMousePosX:Int = lime._internal.backend.native.NativeCFFI.lime_window_get_mouse_pos_x();
		var windowMousePosY:Int = lime._internal.backend.native.NativeCFFI.lime_window_get_mouse_pos_y();

		var window = lime.app.Application.current.window;

		window.x = Math.floor(windowMousePosX - initMousePos.x);
		window.y = Math.floor(windowMousePosY - initMousePos.y);
	}

	function reload(width:Int, height:Int) {
		display.width = width;
		display.height = height;

		titleBar.w = width - 2;
		titleBar.x = 1;
		titleBar.y = 1;
		windowBuffer.updateElement(titleBar);

		for (i in 0...border.length) {
			var part = border[i];
			switch (i) {
				case 0:
					part.x = 1;
					part.y = 0;
					part.w = width - 2;
					part.h = 1;
				case 1:
					part.x = 1;
					part.y = height - 1;
					part.w = width - 2;
					part.h = 1;
				case 2:
					part.x = 0;
					part.y = 0;
					part.w = 1;
					part.h = height;
				case 3:
					part.x = width - 1;
					part.y = 0;
					part.w = 1;
					part.h = height;
				default:
			}

			windowBuffer.updateElement(part);
		}

		icon.x = titleBar.x + 8;
		icon.y = titleBar.y + 6;
		iconBuffer.updateElement(icon);

		text.x = titleBar.x + (icon.x + icon.w) + 4;
		text.y = titleBar.y + Math.round((titleBar.h - (text.height * text.scale)) * 0.5);

		var peoteView = Main.current.peoteView;

		if (display.isIn(peoteView)) {
			peoteView.removeDisplay(display);
			peoteView.addDisplay(display);
		}

		var window = lime.app.Application.current.window;
		visible = !window.fullscreen;
	}
}