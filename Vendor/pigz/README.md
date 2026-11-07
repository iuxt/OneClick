# Bundled pigz source

pigz 2.8 source by Mark Adler, downloaded from the official project at
https://zlib.net/pigz/ . The build compiles `pigz.c`, `yarn.c` and `try.c`
with `NOZOPFLI` and the macOS system zlib. One source fix keeps the `-A`
ZIP-entry alias option available in `NOZOPFLI` builds; upstream accidentally
placed its assignment inside the Zopfli-only conditional.

OneClick invokes the helper for parallel TAR.GZ compression and a compatible
single-file ZIP fast path. TAR output is streamed directly from system bsdtar
without an intermediate file; the configured CPU thread limit applies to pigz.
ZIP output is a standard single-entry ZIP using method 8 (DEFLATE). Encrypted,
split, symbolic-link, executable, directory and ZIP64 inputs continue to use
the bundled 7-Zip helper.
