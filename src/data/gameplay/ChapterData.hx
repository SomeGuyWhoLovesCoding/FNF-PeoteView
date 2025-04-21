package data.gameplay;

/**
	The chapter data from the file.
**/
@:publicFields
typedef ChapterData = {
	var general:GeneralChapterData;
	var songs:Array<ChapterSong>;
}

/**
	The chapter data from the file.
**/
@:publicFields
typedef GeneralChapterData = {
	/**
		The name of the chapter.
	**/
	var name:String;

	/**
		The name of the chapter in the story menu.
	**/
	var description:String;
}

/**
	The chapter data from the file.
**/
@:publicFields
typedef ChapterSong = {
	/**
		The directory of the chapter's song.
	**/
	var dir:String;

	/**
		The icon id of the chapter song in the freeplay menu.
	**/
	var icon:String;

	/**
		What the chapter song is displayed as.
	**/
	var title:String;

	/**
		The color of the chapter song in the freeplay menu.
	**/
	var color:{R:Int, G:Int, B:Int};
}