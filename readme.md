# Welcome!

Funkin' View (AKA FNF' in Peote-View) is a successor of [Friday Night Funkin' Zenith](https://github.com/SomeGuyWhoLovesCoding/Zenith-FNF-Public) and is the fastest running opengl fnf engine in haxe of now.

This is being optimized and organized as frequently as possible for a flexible codebase making it faster to finish. It aims to be the new standard of FNF modding.

This project was started a few months ago, so expect this repository to be very active!\

# Setup

Instll these haxelibs:

Lime - Clone [this lime fork](https://github.com/SomeGuyWhoLovesCoding/lime), do ``haxelib dev lime https://github.com/SomeGuyWhoLovesCoding/lime.git``, THEN do ``lime rebuild tools`` and ``lime rebuild <platform>``, and for future rebuilds you just do the same ``lime rebuild <platform>``. (Thanks to lavender for fixing the main loop fuckery)

Peote-view - ``haxelib git peote-view https://github.com/maitag/peote-view.git``

HXCPP - ``haxelib install hxcpp``

Format - ``haxelib install format`` (This one is also used in peote-view for `TextureData.fromFormatPNG`)

Miniaudio - ``haxelib git miniaudio https://github.com/alchemy-haxe/genkit_miniaudio.git``

Input2Action - ``haxelib install input2action`` (will install 2 dependencies)

After that, make sure that you are on this screen:

![img](repo_assets/image-1.png)

And press "y" to go to the download page for visual studio.

PRESS COMMUNITY!![img](repo_assets/image-2.png)

And it'll automatically download the setup executable for you.

Make sure that you're looking at this window:![img](repo_assets/image.png)

Then, you want to go to the Windows 10 SDK (10.0.19041) and MSVC v143 - VS 2022 C++ x64/x86 build tools (Latest). That's literally it.

(Oh yeah and it requires at least 6GB of free storage space on a drive to install btw)

And you're all set up! Just run `lime test cpp` and it works!

# Credits

- SomeGuyWhoLikesCoding

(AKA SomeGuyWhoLikesFNF, VeryExcited, 0x1DFA7D (someguywhouhhhhh), [SomethingIsItchy](https://somethingisitchy.itch.io), [FelixTheCat](https://gamejolt.com/@SomeGuyWhoLikesFNF), or simply Jeremiah):

: Owner, Maintainer, and Programmer

- Halfwat

(AKA jobf)

: Helped me learn how peote-view works, wrote the sprite clipping sample for peote-view, and more.

- Semmi

(AKA Semmis, maitag, or simply Sylvio Sell)

: Wrote peote-view, and wrote the `slices` shader sample for the sustain note.

- MKI

: Generated the miniaudio bindings via genkit (listed above)

- 494kd

: First compile of the android build and failed because of genkit_miniaudio error

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