# Bundled pigz source

Unmodified pigz 2.8 source by Mark Adler, downloaded from the official
project at https://zlib.net/pigz/ . The build compiles `pigz.c`, `yarn.c`
and `try.c` with `NOZOPFLI` and the macOS system zlib.

OneClick invokes the helper only for a compatible single-file ZIP fast path.
The output is a standard single-entry ZIP using method 8 (DEFLATE). Encrypted,
split, symbolic-link, executable, directory and ZIP64 inputs continue to use
the bundled 7-Zip helper.
