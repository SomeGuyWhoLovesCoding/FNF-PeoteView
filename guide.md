# Notice

This page is WIP. And, it's currently only for you to read through just in case you want to read it again in the future when all the other modding tools and menus are added.

# Introduction

This is the page dedicated for Funkin' View's guide. There will be a shit ton of things in here.

## Chart format

The chart format is an entire folder of everything you need for your custom fnf song. And, the audio can go anywhere since the paths are there for you to change to where you put it or just simply the song's folder.

### The song's chart file

The biggest thing in the chart format. It's a binary file containing 8 bytes per note in a sorted list. It's also designed to be as efficient as possible which is why I rewrote it to not use the HxBigIO haxelib and basically turn it into an hxcpp/hl extern to accelerate the speed further (which is where memory-mapped io comes in).

Here's how the chart note works:

___________________________ ___________________________ ___________________________

- Position

It's a 41 bit integer designed for extreme position making spammy songs even more precise. *10 μs* precision to be exact. It takes up most of the chart note's space. Also, it's a fixed point number so you don't have to worry about losing precision at absurdly big values which happens with floating point numbers.

- Duration

It's a 13 bit integer with the least precision that isn't noticable according to the human reaction time. *5 ms* granularity to be exact. It visually represents the length of a sustain note.

- Index

It's a 4 bit integer that visually represents the index of the current note element the receptor should move it horizontally to.

- Type

It's a 4 bit integer that visually represents the note type that sometimes can have its own subtexture skin.

- Lane

It's a 2 bit integer that visually represents the strumline's index in which you can move your note to.

### The song's header

It's a text file containing readable info of your custom fnf song. This includes multiple genre support and audio paths.

Here's how it's formatted.

```
Title: Song Name
Arist: Artist Name
Genre: Genre 1, Genre 2, Genre 3
Speed: 1.23
BPM: 120
Time Signature: 4/4
Stage: stage
Instrumental: InstPath.flac
Voices: VoicesPath.flac
Mania: 4
Difficulty: #1
Game Over:
Theme: theme
BPM: 100
Characters:
dad, enemy
pos -700 300
cam 0 45
gf, other
pos -100 300
cam 0 45
bf, player
pos 200 300
cam 0 45
bf, player, true
pos 200 300
cam 0 45
```

The third argument of the character "bf" is infact whenever you want to copy it or not. (Only really works if you have an existing character to copy, otherwise it's just meaningless)

The difficulty map:

#1 - Easy
#2 - Normal
#3 - Hard
#4 - Expert
#5 - Insane
#6 - Blasphemous
#7 - Echo
#8 - Custom

___________________________ ___________________________ ___________________________

There's clearly a lot of info there but it's nice to separate it from the chart file.

### The song's event file

It's a text file containing the song's events inside. This includes bpm changes, time signature changes, countdown popups, and more. There are also a bunch of built-in visual events.

The first argument will always be the event's position known as its tag "pos". Before putting in the event type, input "pos [time in ms with decimal]"

Here's how it's formatted:

```
pos 4534.883720930233 ctd 0
pos 4883.720930232559 ctd 1
pos 5232.558139534884 ctd 2
pos 5581.395348837210 ctd 3
pos 11162.79069767442 ctd 3
pos 11162.79069767442 bpm 344 intrp false duration 0.5
pos 101860.4651162791 sig 5/4
pos 203720.9302325582 vignt alpha 1.0 color 0xFF0000FF tween true duration 0.5
pos 203720.9302325582 noise alpha 0.5 color 0xFF0000FF tween true duration 0.5
pos 203720.9302325582 fov 1.5 tween true duration 0.5
pos 203720.9302325582 shake 5 tween true duration 0.5 axis 0
```

7 built-in events total.

Here's how each of them work:

___________________________ ___________________________ ___________________________

- Countdown popup

This event is known as its tag "ctd". Enter a value after the tag between 0 and 3 for the event to show up in the song.

Example: "ctd 2"

- BPM change

This event is known as its tag "bpm". Enter the new bpm value after typing the tag. There are 2 more options with values which are used for interpolation.

Example: "bpm 200 intrp false duration 0.5"

If the "intrp" property is set to "true", the bpm change will be interpolated. Certain FNF songs do this via automation events in an flp.

And, the bpm change's tween is enabled via "tween true".

The bpm change's tween duration can be changed via the last option. The "duration" property.

- Time Signature change

This event is known as its tag "sig". Enter a value after the tag that is a valid time signature.

Example: "sig 6/4"

- Vignette

This event is known as its tag "vignt". There are 4 options with values. The other half of them are used for tweening.

Example: "vignt alpha 0.5 tween true duration 0.5 color 0x000000FF"

The vignette's transparency is set by the "alpha" property.

The vignette's color is set by the "color" property.

And, the vignette's tween is enabled via "tween true".

The vignette's tween duration can be changed via the last option. The "duration" property.

- Noise

This event is known as its tag "noise". There are 4 options with values. The other half of them are used for tweening.

Example: "noise alpha 0.5 tween true duration 0.5 color 0x000000FF"

The noise's transparency is set by the "alpha" property.

The noise's color is set by the "color" property.

And, the noise's tween is enabled via "tween true".

The noise's tween duration can be changed via the last option. The "duration" property.

- Field of View

This event is known as its tag "fov". Enter the new fov value after typing the tag. There are 2 more options with values which are used for tweening.

Example: "fov 2.5 tween true duration 0.5"

The tween is enabled via "tween true".

The tween duration can be changed via the last option. The "duration" property.

- Screen Shake

This event is known as its tag "shake". Enter the shake amount in pixels after typing the tag. There are 3 more options with values in which 2/3 of them are used for tweening.

Example: "shake 5 tween true duration 0.5 axis 0"

The tween is enabled via "tween true".

The tween duration can be changed via the last option. The "duration" property.

The shake axis can be changed via the "axis" property. Anything other than 1 or 2 will default to 0. Horizontal shake is "axis 1" and vertical shake is "axis 2".

___________________________ ___________________________ ___________________________

The event system has not been implemented onto the gameplay state yet. However, that's not my priority right now.

### How to port json

Drag and drop a chart.json onto their song and let it convert to a .cbin. Note, if you already have a `.cbin` file, remove it first so the json can convert.

You can remove the json if you want but I don't care.

So, that's all.