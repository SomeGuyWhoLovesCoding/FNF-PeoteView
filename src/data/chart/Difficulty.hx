package data.chart;

/**
	The song's difficulty.
**/
enum abstract Difficulty(Int) from Int {
	/**
		Easy difficulty level.
	**/
	var EASY;

	/**
		Normal difficulty level.
	**/
	var NORMAL;

	/**
		Hard difficulty level.
	**/
	var HARD;

	/**
		Expert difficulty level.
	**/
	var EXPERT;

	/**
		Insane difficulty level.
	**/
	var INSANE;

	/**
		Blasphemous difficulty level.
	**/
	var BLASPHEMOUS;

	/**
		Echo difficulty level.
	**/
	var ECHO;

	/**
		No difficulty level.
	**/
	var NONE;
}