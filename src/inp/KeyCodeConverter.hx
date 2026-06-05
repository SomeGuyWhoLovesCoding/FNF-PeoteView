package inp;

import lime.ui.KeyCode;

class KeyCodeConverter {
	public static function fromNativeScanCode(nativeScanCode:Int):KeyCode {
		return switch (nativeScanCode) {
			// Letters (USB HID usage IDs to KeyCode)
			case 4: A;
			case 5: B;
			case 6: C;
			case 7: D;
			case 8: E;
			case 9: F;
			case 10: G;
			case 11: H;
			case 12: I;
			case 13: J;
			case 14: K;
			case 15: L;
			case 16: M;
			case 17: N;
			case 18: O;
			case 19: P;
			case 20: Q;
			case 21: R;
			case 22: S;
			case 23: T;
			case 24: U;
			case 25: V;
			case 26: W;
			case 27: X;
			case 28: Y;
			case 29: Z;
			
			// Numbers
			case 30: NUMBER_1;
			case 31: NUMBER_2;
			case 32: NUMBER_3;
			case 33: NUMBER_4;
			case 34: NUMBER_5;
			case 35: NUMBER_6;
			case 36: NUMBER_7;
			case 37: NUMBER_8;
			case 38: NUMBER_9;
			case 39: NUMBER_0;
			
			// Function keys
			case 58: F1;
			case 59: F2;
			case 60: F3;
			case 61: F4;
			case 62: F5;
			case 63: F6;
			case 64: F7;
			case 65: F8;
			case 66: F9;
			case 67: F10;
			case 68: F11;
			case 69: F12;
			
			// Navigation & Control
			case 40: RETURN;
			case 41: ESCAPE;
			case 42: BACKSPACE;
			case 43: TAB;
			case 44: SPACE;
			case 45: MINUS;
			case 46: EQUALS;
			case 47: LEFT_BRACKET;
			case 48: RIGHT_BRACKET;
			case 49: BACKSLASH;
			case 51: SEMICOLON;
			case 52: SINGLE_QUOTE;
			case 53: GRAVE;
			case 54: COMMA;
			case 55: PERIOD;
			case 56: SLASH;
			case 57: CAPS_LOCK;
			
			// Arrows
			case 79: RIGHT;
			case 80: LEFT;
			case 81: DOWN;
			case 82: UP;
			
			// Modifiers
			case 224: LEFT_CTRL;
			case 225: LEFT_SHIFT;
			case 226: LEFT_ALT;
			case 227: LEFT_META;
			case 228: RIGHT_CTRL;
			case 229: RIGHT_SHIFT;
			case 230: RIGHT_ALT;
			case 231: RIGHT_META;
			
			// Lock keys
			case 71: SCROLL_LOCK;
			case 83: NUM_LOCK;
			
			// Numpad
			case 84: NUMPAD_DIVIDE;
			case 85: NUMPAD_MULTIPLY;
			case 86: NUMPAD_MINUS;
			case 87: NUMPAD_PLUS;
			case 88: NUMPAD_ENTER;
			case 89: NUMPAD_1;
			case 90: NUMPAD_2;
			case 91: NUMPAD_3;
			case 92: NUMPAD_4;
			case 93: NUMPAD_5;
			case 94: NUMPAD_6;
			case 95: NUMPAD_7;
			case 96: NUMPAD_8;
			case 97: NUMPAD_9;
			case 98: NUMPAD_0;
			case 99: NUMPAD_PERIOD;
			case 103: NUMPAD_EQUALS;
			case 133: NUMPAD_COMMA;
			
			// Editing
			case 73: INSERT;
			case 74: HOME;
			case 75: PAGE_UP;
			case 76: DELETE;
			case 77: END;
			case 78: PAGE_DOWN;
			
			// Media keys
			case 127: MUTE;
			case 128: VOLUME_UP;
			case 129: VOLUME_DOWN;
			case 258: AUDIO_NEXT;
			case 259: AUDIO_PREVIOUS;
			case 260: AUDIO_STOP;
			case 261: AUDIO_PLAY;
			case 262: AUDIO_MUTE;
			
			// Browser keys
			case 268: APP_CONTROL_SEARCH;
			case 269: APP_CONTROL_HOME;
			case 270: APP_CONTROL_BACK;
			case 271: APP_CONTROL_FORWARD;
			case 272: APP_CONTROL_STOP;
			case 273: APP_CONTROL_REFRESH;
			case 274: APP_CONTROL_BOOKMARKS;
			
			// Application keys
			case 101: APPLICATION;
			case 117: HELP;
			case 118: MENU;
			case 119: SELECT;
			case 120: STOP;
			case 121: AGAIN;
			case 122: UNDO;
			case 123: CUT;
			case 124: COPY;
			case 125: PASTE;
			case 126: FIND;
			
			// System keys
			case 102: POWER;
			case 104: F13;
			case 105: F14;
			case 106: F15;
			case 107: F16;
			case 108: F17;
			case 109: F18;
			case 110: F19;
			case 111: F20;
			case 112: F21;
			case 113: F22;
			case 114: F23;
			case 115: F24;
			case 116: EXECUTE;
			case 153: ALT_ERASE;
			case 154: SYSTEM_REQUEST;
			case 155: CANCEL;
			case 156: CLEAR;
			case 157: PRIOR;
			case 158: RETURN2;
			case 159: SEPARATOR;
			case 160: OUT;
			case 161: OPER;
			case 162: CLEAR_AGAIN;
			case 163: CRSEL;
			case 164: EXSEL;
			
			// Numpad extras
			case 176: NUMPAD_00;
			case 177: NUMPAD_000;
			case 178: THOUSAND_SEPARATOR;
			case 179: DECIMAL_SEPARATOR;
			case 180: CURRENCY_UNIT;
			case 181: CURRENCY_SUBUNIT;
			case 182: NUMPAD_LEFT_PARENTHESIS;
			case 183: NUMPAD_RIGHT_PARENTHESIS;
			case 184: NUMPAD_LEFT_BRACE;
			case 185: NUMPAD_RIGHT_BRACE;
			case 186: NUMPAD_TAB;
			case 187: NUMPAD_BACKSPACE;
			case 188: NUMPAD_A;
			case 189: NUMPAD_B;
			case 190: NUMPAD_C;
			case 191: NUMPAD_D;
			case 192: NUMPAD_E;
			case 193: NUMPAD_F;
			case 194: NUMPAD_XOR;
			case 195: NUMPAD_POWER;
			case 196: NUMPAD_PERCENT;
			case 197: NUMPAD_LESS_THAN;
			case 198: NUMPAD_GREATER_THAN;
			case 199: NUMPAD_AMPERSAND;
			case 200: NUMPAD_DOUBLE_AMPERSAND;
			case 201: NUMPAD_VERTICAL_BAR;
			case 202: NUMPAD_DOUBLE_VERTICAL_BAR;
			case 203: NUMPAD_COLON;
			case 204: NUMPAD_HASH;
			case 205: NUMPAD_SPACE;
			case 206: NUMPAD_AT;
			case 207: NUMPAD_EXCLAMATION;
			case 208: NUMPAD_MEM_STORE;
			case 209: NUMPAD_MEM_RECALL;
			case 210: NUMPAD_MEM_CLEAR;
			case 211: NUMPAD_MEM_ADD;
			case 212: NUMPAD_MEM_SUBTRACT;
			case 213: NUMPAD_MEM_MULTIPLY;
			case 214: NUMPAD_MEM_DIVIDE;
			case 215: NUMPAD_PLUS_MINUS;
			case 216: NUMPAD_CLEAR;
			case 217: NUMPAD_CLEAR_ENTRY;
			case 218: NUMPAD_BINARY;
			case 219: NUMPAD_OCTAL;
			case 220: NUMPAD_DECIMAL;
			case 221: NUMPAD_HEXADECIMAL;
			
			// Special
			case 70: PRINT_SCREEN;
			case 72: PAUSE;
			case 257: MODE;
			case 263: MEDIA_SELECT;
			case 264: WWW;
			case 265: MAIL;
			case 266: CALCULATOR;
			case 267: COMPUTER;
			case 275: BRIGHTNESS_DOWN;
			case 276: BRIGHTNESS_UP;
			case 277: DISPLAY_SWITCH;
			case 278: BACKLIGHT_TOGGLE;
			case 279: BACKLIGHT_DOWN;
			case 280: BACKLIGHT_UP;
			case 281: EJECT;
			case 282: SLEEP;
			
			case _: UNKNOWN;
		}
	}
}