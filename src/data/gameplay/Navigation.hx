package data.gameplay;

/**
	The navigation class.
	I'm serious. This class was made to reduce boilerplate inside menus where it would be uneccessary to have the same code over and over for everything. 
**/
@:publicFields
@:noDebug
abstract Navigation(Int) {
	inline function new() this = 0;

	inline function scroll(amount:Int) {
		this += amount;
	}

	inline function setTo(amount:Int) {
		this = amount;
	}

	inline function reset() {
		this = 0;
	}

	inline function resetIfOver(amount:Int) {
		if (this >= amount) {
			this = 0;
		}
	}

	inline function resetIfUnder(setTo:Int) {
		if (this < 0) {
			this = setTo;
		}
	}

	inline function resetIfBoth(over:Int, setTo:Int) {
		resetIfOver(over);
		resetIfUnder(setTo);
	}

	inline function value() return this;
}