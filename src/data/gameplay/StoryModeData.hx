package data.gameplay;

/**
	The story mode data from the story mode file.
**/
@:publicFields
typedef StoryModeData = {
	var meta:StoryModeMeta;
	var startingWeek:String;
	var chapters:Array<StoryModeChapter>;
}

/**
	The metadata from the story mode file.
**/
@:publicFields
typedef StoryModeMeta = {
	/**
		What this mod's story should be called from the file.
	**/
	var title:String;

	/**
		The id of this mod's story.
	**/
	var id:String;

	/**
		What this mod's story is about, in a single synopsis.
	**/
	var description:String;
}

/**
	The sory mode chapter data from the story mode file.
**/
@:publicFields
typedef StoryModeChapter = {
	/**
		What this mod's story chapter should be called from the file.
	**/
	var title:String;

	/**
		The id of this mod's story chapter, for convenience.
	**/
	var id:String;

	/**
		The chapter path of this mod's story chapter, so it knows where it is.
	**/
	var chapterPath:String;

	/**
		The cutscene path of this mod's story chapter, so it knows where to play cutscenes at, as long as the video with the respective file name being the current song exists.
	**/
	@:optional var cutscenePath:String;

	/**
		The dialogue path of this mod's story chapter, so it knows where to play dialogue at, as long as the dialogue file with the respective file name being the current song exists.
	**/
	@:optional var dialoguePath:String;

	/**
		The next week's id to play. This is here because the current week's choices can travel you to a completely non-linear week direction which can ruin the pace if you don't have this specific value.
	**/
	var next:String;

	/**
		The requirements to play this current story week.
		An array of strings that represent the flags that get checked if they exist. If all of the flags exist, it means you will unlock the week.
	**/
	var requirements:Array<String>;

	/**
		This creates the flags that will happen after you finish a story week.
	**/
	var setSaveFlags:Array<String>;

	/**
		The week you'll be redirected to if this week's locked.
	**/
	var redirectIfLocked:String;
}