# Welcome!

Funkin' View (AKA FNF' in Peote-View) is a successor of [Friday Night Funkin' Zenith](https://github.com/SomeGuyWhoLovesCoding/Zenith-FNF-Public) and is the fastest running opengl fnf engine in haxe of now.

This is being optimized and organized as frequently as possible for a flexible codebase making it faster to finish. It aims to be the new standard of FNF modding.

Expect this repository to be somewhat or sometimes active, because the developer has other stuff to do so don't go "when is funkin view coming out".

# Targets

Funkin' View currently supports the following targets:

```
lime test windows
lime test linux
lime test android // not supported yet unless compiled
lime test hl
```

# Optimizations included

Optimizations that were ingrained into this "wholesome" fnf rewrite (listed in alphabetical order) is:

- Camera Culling: Obvious, simply cuts out rendering for anything out of bounds. Used for the notes and sustains
- Fake Object Overlap Rendering: If a certain object overlaps one another, cancel that object and make that other object's pixels have doubled its alpha. Used for the notes.
- Memory Mapping: Stores your file within the os's internal memory map instead of dumping it all onto your RAM. Used for the chart file's internal code.
- Object Pooling: Also obvious, but simply reuses a dead object. Used for the freeplay selection text and icon stuff, and notes and sustains.
- Packer Atlas: Never done yet but will be for the characters.
- Static buffer and program cache: Just there for a bit of muddiness in the code's structure but helps improve loading times excellently! Used in every single menu you can think of in Funkin' View.
- Texture Sheet: Simple. Just clip a certain part of the image and have it present a sprite animation. Heavily used in sparrow atlas, and even simple stuff such as the icon grid, the note spritesheets, the pause menu sheet, etc etc. you name it.

And that was all Funkin' View has to offer!

...and the fact that peote-view is literally an opengl wrapper that intructs most of its rendering optimization tricks for you.

PS. Windows Developers are geniuses like what logic made them think "oh, we should do this "memory-mapping" idea for performance-critical applications".

# Preinstalled packages

Hashlink 1.15 (located at hashlinkBuildXmls/hl)

# Setup

You must have haxe 4.3.6 (and newer) installed.

Instll these haxelibs:

Lime - Clone [this lime fork](https://github.com/SomeGuyWhoLovesCoding/lime), do ``haxelib dev lime [path you cloned the fork at]``, THEN do ``lime rebuild tools`` and ``lime rebuild <platform>``, and for future rebuilds you just do the same ``lime rebuild <platform>``. (Thanks to lavender for fixing the main loop fuckery)

Peote-view - ``haxelib install peote-view``

HXCPP - ``haxelib install hxcpp``

Format - ``haxelib install format`` (This one is also used in peote-view for `TextureData.fromFormatPNG`)

Input2Action - ``haxelib install input2action`` (will install 2 dependencies)

CustomTitleBar - ``haxelib git customtitlebar https://github.com/Blossomical/customtitlebar.git`` (thank you so fuckin much blossomical)

After that, make sure that you are on this screen after running ``haxelib lime setup``:

**Windows (10 OR GREATER)**

![img](repo_assets/image-1.png)

And press "y" to go to the download page for visual studio.

PRESS COMMUNITY!![img](repo_assets/image-2.png)

And it'll automatically download the setup executable for you.

Make sure that you're looking at this window:![img](repo_assets/image.png)

Then, you want to go to the Windows 10 SDK (10.0.19041) and MSVC v143 - VS 2022 C++ x64/x86 build tools (Latest). That's literally it.

(Oh yeah and it requires at least 6GB of free storage space on a drive to install btw)

**Linux (DEBIAN/UBUNTU)**

Run the file named ``setup-linux.bash``.

And you're all set up!

HXCPP setup
---

Just run `lime test cpp` and it works!

Hashlink setup
---

If you want to compile the hl extern code you just modified, or you just want to set up hashlink compilation, do these two steps:

- (not required) `lime setup hl` and copy your path (with `hashlinkBuildXmls/hl`) to the path before pressing enter.

- Run the build.xml's in "hashlinkBuildXmls" folder at the root source directory.

Then, go to https://github.com/Blossomical/customtitlebar#hashlink-setup for instructions on how to build the library to hdll

Then, you just `lime test hl` and everything runs good!

...but except if you want to switch your hl version you have to recompile all the xml's...isn't that required...? Yes. It is required.

# Credits

- SomeGuyWhoLikesCoding

(AKA SomeGuyWhoLikesFNF, VeryExcited, 0x1DFA7D (someguywhouhhhhh), [SomethingIsItchy](https://somethingisitchy.itch.io), [FelixTheCat](https://gamejolt.com/@SomeGuyWhoLikesFNF), or simply Jeremiah):

: Owner, Maintainer, and Programmer

- Halfwat

(AKA jobf)

: Tester (Helped me learn how peote-view works, wrote the sprite clipping sample for peote-view, and more.)

- Semmi

(AKA Semmis, maitag, or simply Sylvio Sell)

: Peote-view (Wrote peote-view, and wrote the `slices` shader sample for the sustain note.)

- Blossimical

: Helper (Wrote the customtitlebar haxelib tool. For real, seriously, not joking, I've been waiting for this moment for long enough.)

# Frequently Asked Questions

Q1. Funkin' View takes a very long time to boot! What should I do!?

A1. Just reboot your computer and everything will be fine.

- Explanation: My co-programmer jobf AKA half had experienced the issue half an hour before writing this first FAQ.

Q2. Funkin' View's codebase is very hard to understand.

A2. I mean, what did you expect? It's written in a very low level programming language and I recommend that you learn it before digging around the repository.

Q3. Why do you use static variables for the program and buffer? Isn't that like, unclean?

A3. I use static variables to cache the memory inside the app before it was closed.

- Explanation: It's obvious. Look in a class on the "structures" package.

Q4. My game won't open when compiling with `-D FV_PROFILE`. What should I do?

A4. This is a normal issue I've experienced, so for now, you can delete the `haxe` and `obj` folders and try again.
