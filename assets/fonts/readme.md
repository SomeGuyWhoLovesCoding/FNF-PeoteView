### Introduction

Hello there. If you're reading this and finding out what folder this is,
this folder is where all of the runtime-converted bitmap fonts come from in your export folder.

Yes, I mean it.

#### How it works

This automatic bitmap font generator uses the tool used under the hood with specific arguments I've put out to be similar to the old bitmap font system.

The process is simple: run fontbm, THEN read the outputted files generated from there, and convert it to a 7 element array
where it's then read via the `elements.Text` class.

#### Tools used

- [FontBM (Cross-platform variant of angelcode's BMFont program)](https://github.com/vladimirgamalyan/fontbm)