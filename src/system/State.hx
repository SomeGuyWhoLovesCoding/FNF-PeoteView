package system;

/**
	The state.
**/
#if !debug
@:noDebug
#end
@:publicFields
class State {
	/**
		The static instance of the state.
	**/
	static var current:State = new State();

	/**
		Whenever you want to use the gc or not.
		If the value is true, the old state will be freed up from memory immediately, and other stuff that have no references left will.
	**/
	static var useGC:Bool = false;

	/**
		Constructs a state.
	**/
	function new() {}

	/**
		Updates the state.
		@param deltaTime The time since the last frame.
	**/
	function update(deltaTime:Float) {}

	/**
		Override this to add your code to your own state.
		@param keyCode The keycode.
		@param modifier The key modifier.
	**/
	function onKeyDown(keyCode:lime.ui.KeyCode, modifier:lime.ui.KeyModifier) {}

	/**
		Override this to add your code to your own state.
		@param keyCode The keycode.
		@param modifier The key modifier.
	**/
	function onKeyUp(keyCode:lime.ui.KeyCode, modifier:lime.ui.KeyModifier) {}

	/**
		Frees the old state from memory when switching a state.
	**/
	function dispose() {}
}