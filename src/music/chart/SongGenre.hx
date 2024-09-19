package music.chart;

/**
	The song's genre.
	This is an abstract over string.
 */
#if !debug
@:noDebug
#end
@:publicFields
enum abstract SongGenre(String) from String {
	/**
		The classical genre.
	**/
	var CLASSICAL = "Classical";

	/**
		Dull metal.
	**/
	var DULL_METAL = "Dull Metal";

	/**
		Classic metal.
	**/
	var CLASSIC_METAL = "Classic Metal";

	/**
		Light metal.
	**/
	var LIGHT_METAL = "Light Metal";

	/**
		Alternative metal.
	**/
	var ALT_METAL = "Alternative Metal";

	/**
		Heavy metal.
	**/
	var HEAVY_METAL = "Heavy Metal";

	/**
		Dull rock.
	**/
	var DULL_ROCK = "Dull Rock";

	/**
		Classic rock.
	**/
	var CLASSIC_ROCK = "Classic Rock";

	/**
		Light rock.
	**/
	var LIGHT_ROCK = "Light Rock";

	/**
		Alternative rock.
	**/
	var ALT_ROCK = "Alternative Rock";

	/**
		Heavy rock.
	**/
	var HEAVY_ROCK = "Heavy Rock";

	/**
		Light pop.
	**/
	var LIGHT_POP = "Light Pop";

	/**
		Heavy pop.
	**/
	var HEAVY_POP = "Heavy Pop";

	/**
		House EDM.
	**/
	var HOUSE = "House";

	/**
		Techno EDM.
	**/
	var TECHNO = "Techno";

	/**
		Ambient EDM.
	**/
	var AMBIENT = "Ambient";

	/**
		Breakbeat EDM.
	**/
	var BREAKBEAT = "Breakbeat";

	/**
		Dub EDM.
	**/
	var DUB = "Dub";

	/**
		Acid Techno EDM.
	**/
	var ACID_TECHNO = "Acid Techno";

	/**
		Dubstep EDM.
	**/
	var DUBSTEP = "Dubstep";

	/**
		Industrial Hardcore EDM.
	**/
	var IND_HARDCORE = "Industrial Hardcore EDM";

	/**
		Acid Breaks EDM.
	**/
	var ACID_BREAKS = "Acid Breaks";

	/**
		Brazilian Bass EDM.
	**/
	var BRAZ_BASS = "Brazilian Bass";

	/**
		Trap EDM.
	**/
	var TRAP = "EDM Trap";

	/**
		Dutch House EDM.
	**/
	var DUTCH_HOUSE = "Dutch House";

	/**
		Dark Ambient EDM.
	**/
	var DARK_AMBIENT = "Dark Ambient";

	/**
		Funk.
	**/
	var FUNK = "Funk";

	/**
		Retro Nintendo.
	**/
	var RETRO_NINTENDO = "Retro (Nintendo)";

	/**
		Retro Sega.
	**/
	var RETRO_SEGA = "Retro (Sega)";

	/**
		Retro.
	**/
	var RETRO_OTHER = "Retro (Other)";

	/**
		Ancient.
	**/
	var ANCIENT = "Ancient";

	/**
		Breakcore.
	**/
	var BREAKCORE = "Breakcore";

	/**
		Speedcore.
	**/
	var SPEEDCORE = "Speedcore";

	/**
		Extratone.
	**/
	var EXTRATONE = "Extratone";

	/**
		Hypertone.
	**/
	var HYPERTONE = "Hypertone";

	/**
		Splittertone.
	**/
	var SPLITTERTONE = "Splittertone";
}