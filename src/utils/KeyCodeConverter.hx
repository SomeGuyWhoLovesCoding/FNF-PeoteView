package utils;

import lime.ui.KeyCode;

/**
    lime.ui.KeyCode converter deepseek generated for me. You can use this if you want, idc.
    @since 0.94
**/
class KeyCodeConverter
{
    /**
     * Converts a KeyCode to its human-readable name or literal symbol
     * @param keyCode The KeyCode to convert
     * @return String representation of the key
     */
    public static function getKeyName(keyCode:KeyCode):String
    {
        return switch (keyCode)
        {
            // Special keys
            case UNKNOWN: "[_]";
            case BACKSPACE: "Backspace";
            case TAB: "Tab";
            case RETURN: "Return";
            case ESCAPE: "Escape";
            case SPACE: "Space";
            case DELETE: "Delete";
            
            // Symbols (literal characters)
            case EXCLAMATION: "!";
            case QUOTE: "\"";
            case HASH: "#";
            case DOLLAR: "$";
            case PERCENT: "%";
            case AMPERSAND: "&";
            case SINGLE_QUOTE: "'";
            case LEFT_PARENTHESIS: "(";
            case RIGHT_PARENTHESIS: ")";
            case ASTERISK: "*";
            case PLUS: "+";
            case COMMA: ",";
            case MINUS: "-";
            case PERIOD: ".";
            case SLASH: "/";
            case COLON: ":";
            case SEMICOLON: ";";
            case LESS_THAN: "<";
            case EQUALS: "=";
            case GREATER_THAN: ">";
            case QUESTION: "?";
            case AT: "@";
            case LEFT_BRACKET: "[";
            case BACKSLASH: "\\";
            case RIGHT_BRACKET: "]";
            case CARET: "^";
            case UNDERSCORE: "_";
            case GRAVE: "`";
            
            // Number keys
            case NUMBER_0: "0";
            case NUMBER_1: "1";
            case NUMBER_2: "2";
            case NUMBER_3: "3";
            case NUMBER_4: "4";
            case NUMBER_5: "5";
            case NUMBER_6: "6";
            case NUMBER_7: "7";
            case NUMBER_8: "8";
            case NUMBER_9: "9";
            
            // Alphabet keys
            case A: "A";
            case B: "B";
            case C: "C";
            case D: "D";
            case E: "E";
            case F: "F";
            case G: "G";
            case H: "H";
            case I: "I";
            case J: "J";
            case K: "K";
            case L: "L";
            case M: "M";
            case N: "N";
            case O: "O";
            case P: "P";
            case Q: "Q";
            case R: "R";
            case S: "S";
            case T: "T";
            case U: "U";
            case V: "V";
            case W: "W";
            case X: "X";
            case Y: "Y";
            case Z: "Z";
            
            // Function keys
            case F1: "F1";
            case F2: "F2";
            case F3: "F3";
            case F4: "F4";
            case F5: "F5";
            case F6: "F6";
            case F7: "F7";
            case F8: "F8";
            case F9: "F9";
            case F10: "F10";
            case F11: "F11";
            case F12: "F12";
            case F13: "F13";
            case F14: "F14";
            case F15: "F15";
            case F16: "F16";
            case F17: "F17";
            case F18: "F18";
            case F19: "F19";
            case F20: "F20";
            case F21: "F21";
            case F22: "F22";
            case F23: "F23";
            case F24: "F24";
            
            // Navigation keys
            case HOME: "Home";
            case END: "End";
            case PAGE_UP: "Page Up";
            case PAGE_DOWN: "Page Down";
            case INSERT: "Insert";
            case PRINT_SCREEN: "Print Screen";
            case SCROLL_LOCK: "Scroll Lock";
            case PAUSE: "Pause";
            
            // Arrow keys
            case UP: "↑";
            case DOWN: "↓";
            case LEFT: "←";
            case RIGHT: "→";
            
            // Modifier keys
            case CAPS_LOCK: "Caps Lock";
            case NUM_LOCK: "Num Lock";
            case LEFT_CTRL: "Left Ctrl";
            case LEFT_SHIFT: "Left Shift";
            case LEFT_ALT: "Left Alt";
            case LEFT_META: "Left Meta";
            case RIGHT_CTRL: "Right Ctrl";
            case RIGHT_SHIFT: "Right Shift";
            case RIGHT_ALT: "Right Alt";
            case RIGHT_META: "Right Meta";
            case MODE: "Mode";
            
            // Numpad keys
            case NUMPAD_0: "Num 0";
            case NUMPAD_1: "Num 1";
            case NUMPAD_2: "Num 2";
            case NUMPAD_3: "Num 3";
            case NUMPAD_4: "Num 4";
            case NUMPAD_5: "Num 5";
            case NUMPAD_6: "Num 6";
            case NUMPAD_7: "Num 7";
            case NUMPAD_8: "Num 8";
            case NUMPAD_9: "Num 9";
            case NUMPAD_DIVIDE: "Num /";
            case NUMPAD_MULTIPLY: "Num *";
            case NUMPAD_MINUS: "Num -";
            case NUMPAD_PLUS: "Num +";
            case NUMPAD_ENTER: "Num Enter";
            case NUMPAD_PERIOD: "Num .";
            case NUMPAD_EQUALS: "Num =";
            case NUMPAD_COMMA: "Num ,";
            
            // Media keys
            case AUDIO_NEXT: "Next Track";
            case AUDIO_PREVIOUS: "Previous Track";
            case AUDIO_STOP: "Stop";
            case AUDIO_PLAY: "Play/Pause";
            case AUDIO_MUTE: "Mute";
            case VOLUME_UP: "Volume Up";
            case VOLUME_DOWN: "Volume Down";
            case MEDIA_SELECT: "Media Select";
            case WWW: "Web";
            case MAIL: "Mail";
            case CALCULATOR: "Calculator";
            case COMPUTER: "Computer";
            case EJECT: "Eject";
            case SLEEP: "Sleep";
            
            // Application keys
            case APPLICATION: "Application";
            case EXECUTE: "Execute";
            case HELP: "Help";
            case MENU: "Menu";
            case SELECT: "Select";
            case STOP: "Stop";
            case AGAIN: "Again";
            case UNDO: "Undo";
            case CUT: "Cut";
            case COPY: "Copy";
            case PASTE: "Paste";
            case FIND: "Find";
            
            // Browser/App control keys
            case APP_CONTROL_SEARCH: "Search";
            case APP_CONTROL_HOME: "Browser Home";
            case APP_CONTROL_BACK: "Browser Back";
            case APP_CONTROL_FORWARD: "Browser Forward";
            case APP_CONTROL_STOP: "Browser Stop";
            case APP_CONTROL_REFRESH: "Refresh";
            case APP_CONTROL_BOOKMARKS: "Bookmarks";
            
            // Display/brightness keys
            case BRIGHTNESS_DOWN: "Brightness Down";
            case BRIGHTNESS_UP: "Brightness Up";
            case DISPLAY_SWITCH: "Display Switch";
            case BACKLIGHT_TOGGLE: "Backlight Toggle";
            case BACKLIGHT_DOWN: "Backlight Down";
            case BACKLIGHT_UP: "Backlight Up";
            
            // Other keys
            case POWER: "Power";
            case CANCEL: "Cancel";
            case CLEAR: "Clear";
            case RETURN2: "Return";
            case SEPARATOR: "Separator";
            
            // Default case
            case _: "[_]";
        }
    }
    
    /**
     * Gets a simplified key name (e.g., for keyboard shortcuts display)
     * @param keyCode The KeyCode to convert
     * @return Simplified string representation
     */
    public static function getSimpleKeyName(keyCode:KeyCode):String
    {
        return switch (keyCode)
        {
            case UP: "Up";
            case DOWN: "Down";
            case LEFT: "Left";
            case RIGHT: "Right";
            case RETURN: "Enter";
            case ESCAPE: "Esc";
            case DELETE: "Del";
            case INSERT: "Ins";
            case PAGE_UP: "PgUp";
            case PAGE_DOWN: "PgDn";
            case PRINT_SCREEN: "PrtSc";
            case SCROLL_LOCK: "Scrlk";
            case CAPS_LOCK: "Caps";
            case NUM_LOCK: "Num";
            case LEFT_CTRL: "Ctrl";
            case LEFT_SHIFT: "Shift";
            case LEFT_ALT: "Alt";
            case LEFT_META: "Win";
            case RIGHT_CTRL: "Ctrl";
            case RIGHT_SHIFT: "Shift";
            case RIGHT_ALT: "Alt";
            case RIGHT_META: "Win";
            case _: getKeyName(keyCode);
        }
    }
    
    /**
     * Checks if the key is a modifier key
     * @param keyCode The KeyCode to check
     * @return True if the key is a modifier key
     */
    public static function isModifierKey(keyCode:KeyCode):Bool
    {
        return switch (keyCode)
        {
            case LEFT_CTRL, RIGHT_CTRL, LEFT_SHIFT, RIGHT_SHIFT, 
                 LEFT_ALT, RIGHT_ALT, LEFT_META, RIGHT_META, 
                 CAPS_LOCK, NUM_LOCK, MODE:
                true;
            case _: false;
        }
    }
    
    /**
     * Checks if the key is an arrow key
     * @param keyCode The KeyCode to check
     * @return True if the key is an arrow key
     */
    public static function isArrowKey(keyCode:KeyCode):Bool
    {
        return switch (keyCode)
        {
            case UP, DOWN, LEFT, RIGHT: true;
            case _: false;
        }
    }
    
    /**
     * Checks if the key is a function key (F1-F24)
     * @param keyCode The KeyCode to check
     * @return True if the key is a function key
     */
    public static function isFunctionKey(keyCode:KeyCode):Bool
    {
        return switch (keyCode)
        {
            case F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, 
                 F11, F12, F13, F14, F15, F16, F17, F18, 
                 F19, F20, F21, F22, F23, F24:
                true;
            case _: false;
        }
    }
    
    /**
     * Checks if the key is a navigation key (Home, End, Page Up/Down, Insert)
     * @param keyCode The KeyCode to check
     * @return True if the key is a navigation key
     */
    public static function isNavigationKey(keyCode:KeyCode):Bool
    {
        return switch (keyCode)
        {
            case HOME, END, PAGE_UP, PAGE_DOWN, INSERT: true;
            case _: false;
        }
    }
    
    /**
     * Checks if the key produces a printable character
     * @param keyCode The KeyCode to check
     * @return True if the key produces a printable character
     */
    public static function isPrintable(keyCode:KeyCode):Bool
    {
        return switch (keyCode)
        {
            case A, B, C, D, E, F, G, H, I, J, K, L, M,
                 N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
                 NUMBER_0, NUMBER_1, NUMBER_2, NUMBER_3, NUMBER_4,
                 NUMBER_5, NUMBER_6, NUMBER_7, NUMBER_8, NUMBER_9,
                 SPACE, EXCLAMATION, QUOTE, HASH, DOLLAR, PERCENT,
                 AMPERSAND, SINGLE_QUOTE, LEFT_PARENTHESIS, RIGHT_PARENTHESIS,
                 ASTERISK, PLUS, COMMA, MINUS, PERIOD, SLASH, COLON,
                 SEMICOLON, LESS_THAN, EQUALS, GREATER_THAN, QUESTION,
                 AT, LEFT_BRACKET, BACKSLASH, RIGHT_BRACKET, CARET,
                 UNDERSCORE, GRAVE:
                true;
            case _: false;
        }
    }
}