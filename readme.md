# Welcome!

Funkin' View is a remake of [Friday Night Funkin'](https://www.github.com/FunkinCrew/Funkin) in [Peote-View](https://github.com/maitag/peote-view) as a successor to [Friday Night Funkin' Zenith](https://github.com/SomeGuyWhoLovesCoding/Zenith-FNF-Public) (also check out its dog codebase) as it aims to be the best performing FNF project in haxe (possibly), whilst also being stable as a rock.

Refer to [the wiki](https://github.com/SomeGuyWhoLovesCoding/FNF-PeoteView/wiki/The-Basics) for more info.

**NOTE:** As of right now, Funkin' View is already not so stable (even less on AMD GPUs). Please pull in issue requests if you somehow manage to crack whatever causes it. Be sure to test the latest stable action build with the green checkmark on it to see if you get any issues.

Test with the `FV_NO_MINIAUDIO` flag to isolate quick debug.

## Links
- [Discord Server](https://discord.gg/XrV2UmRbNM)
- [Prerelease Builds](https://github.com/SomeGuyWhoLovesCoding/FNF-PeoteView/actions/workflows/main.yml) (GitHub Actions) - Requires you to be logged into GitHub to download the latest builds.

## Requirements
- [Haxe](https://haxe.org)

- Lime (develop branch/8.4.0) - Most of the libraries require Lime to function.
- Peote-View
- Hxp
- Input2Action
- Format
- A specialized build of Linc_Luajit ([linc_luajit_funkinview](https://github.com/SomeGuyWhoLovesCoding/linc_luajit_funkinview.git))

If you already have Haxe installed, then it would be easy to simply run the following in your terminal:

`haxelib git hxcpp https://github.com/SomeGuyWhoLovesCoding/hxcpp-sgwlfnf.git
haxelib git lime https://github.com/openfl/lime.git develop
haxelib install format
haxelib git linc_luajit_funkinview https://github.com/SomeGuyWhoLovesCoding/linc_luajit_funkinview.git`

**NOTE:** Funkin' View is backward compatible with lime versions under 8.4.0 under the define `LIME_840` being off.

## Old Desc. Elements

This aims to have a flexible codebase to make it faster to read in development terms. It aims to be a newfound competition against psych engine, as both are alike but not architecturally similar in any way.

Expect this repository to be somewhat active with a burst of commits during the month. Please respect the developer's work with intention to either mess around with the source code or play already-compiled builds that'll be shown when v0.99 releases, which will be an experimental global release during its existence.