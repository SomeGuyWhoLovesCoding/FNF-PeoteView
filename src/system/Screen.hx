package system;

import lime.ui.Window;

/**
 * The screen.
 */
#if !debug
@:noDebug
#end
@:publicFields
class Screen extends Display {
	/**
	 * The initial state.
	 */
	inline private static var initState:Class<State> = BasicState;

	/**
	 * The view of the screen.
	 */
	static var view:PeoteView;

	/**
	 * Initialize the screen.
	 */
	static function init(window:Window) {
		view = new PeoteView(window);

		switchState(initState);
	}

	/**
	 * Switch the state.
	 * @param name
	 */
	static function switchState(name:Dynamic) {
		// todo, add a 'dispose' function to State where you can clear the buffers and remove programs from the Display
		// or you can have Display on the State and then remove that from peote-view during 'dispose'

		State.current = null;

		/**
		 * Free up memory from the old buffer.
		 */
		if (State.useGC)
		{
			GC.run();
		}

		State.current = (name is Class) ? Type.createInstance(name, []) : name;
	}
}