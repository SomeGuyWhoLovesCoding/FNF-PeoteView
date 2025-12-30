/*
  minivorbis.h -- libvorbis decoder in a single header
  Project URL: https://github.com/edubart/minivorbis

  This is libogg 1.3.4 + libvorbis 1.3.7 contained in a single header
  to be bundled in C/C++ applications with ease for decoding OGG sound files.
  Ogg Vorbis is a open general-purpose compressed audio format
  for mid to high quality audio and music at fixed and variable bitrates.

  Do the following in *one* C file to implement Ogg and Vorbis:
    #define OGG_IMPL
    #define VORBIS_IMPL

  Optionally provide the following defines:
    OV_EXCLUDE_STATIC_CALLBACKS     - exclude the default static callbacks

  Note that almost no modification was made in the Ogg/Vorbis implementation code,
  thus there are some C variable names that may collide with your code,
  therefore it is best to declare the implementation in dedicated C file.

  LICENSE
    BSD-like License, same as libogg and libvorbis, see end of file.
*/
#ifdef OGG_IMPL
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __cplusplus
}
#endif
#endif /* OGG_IMPL */
#ifdef VORBIS_IMPL
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __cplusplus
}
#endif
#endif /* VORBIS_IMPL */
/*
Copyright (c) 2002-2020 Xiph.org Foundation
Copyright (c) 2020 Eduardo Bart (https://github.com/edubart)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
