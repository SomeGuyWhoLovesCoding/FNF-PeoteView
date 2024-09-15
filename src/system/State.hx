package system;

import peote.view.PeoteView;
import peote.view.Buffer;
import peote.view.Display;
import peote.view.Program;
import peote.view.Color;
import utils.Loader;

/**
 * The state.
 */
@:publicFields
class State {
    /**
     * The static instance of the state.
     */
    static var current:State = new State();

    /**
     * Whenever you want to use the gc or not.
     * If the value is true, the old state will be freed up from memory immediately, and other stuff that has no referneces left on it will.
     */
    static var useGC:Bool = false;
    
    
    /**
     * Constructs a state.
     */
    function new() {
    }


    /**
     * Updates the state.
     * @param deltaTime 
     */
    function updateState(deltaTime:Int) {
        // todo ?
    }

    /**
     * Override this to add your code to your own state.
     * @param keyCode 
     * @param modifier 
     */
    function onKeyDown(keyCode:lime.ui.KeyCode, modifier:lime.ui.KeyModifier) {}

    /**
     * Override this to add your code to your own state.
     * @param keyCode 
     * @param modifier 
     */
    function onKeyUp(keyCode:lime.ui.KeyCode, modifier:lime.ui.KeyModifier) {}
}