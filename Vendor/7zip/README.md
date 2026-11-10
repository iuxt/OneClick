# Bundled 7-Zip command line tool

7-Zip 26.06 for macOS (2026-11-06), universal arm64/x86_64.
The universal executable is assembled with `lipo -create` from the official
arm64 and x86_64 distributions; neither architecture slice is modified.
The app invokes this separate executable for encrypted ZIP/7Z creation and
ZIP/7Z/RAR extraction. It requires no external installation or network access.

- Project: https://www.7-zip.org/
- arm64 distribution: https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz
- x86_64 distribution: https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac-x64.tar.xz
- Corresponding source: https://github.com/ip7z/7zip/releases/download/26.06/7z2606-src.tar.xz
- Source repository/tag: https://github.com/ip7z/7zip/tree/26.06
- arm64 archive SHA-256: `b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd`
- x86_64 archive SHA-256: `3af68b124052da7fc2a246c96b0bea6a68bfee389baa788f4cead1a133445586`
- Source archive SHA-256: `a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4`
- Original arm64 executable SHA-256: `56cf8eb2fdc6f9c0ac5d7a3cd238505814ac8ed6b88a7c64a7e3256036252c60`
- Original x86_64 executable SHA-256: `d54aa0864244abeef158772fbde3dd9bac2b93a54c564a76c4334c5a8bcaf35a`
- Combined universal executable SHA-256: `b190ccc5220ac0f77fd739bde72639ef6dcd0a4644e56729d70b850a017aa74d`

Distribution hashes were verified against the official GitHub release asset
digests. To reproduce the universal executable, extract the two macOS archives
into separate directories and run:

```sh
lipo -create mac-arm64/7zz mac-x64/7zz -output 7zz
```

The build copies `7zz` into `OneClick.app/Contents/Helpers/` and signs the copy with
`7zz.entitlements`, an empty entitlement set; the non-sandboxed host and helper
use normal filesystem access. Signing changes the hash of
the app-bundled copy; the vendored file remains the upstream binary.

See `License.txt` and `COPYING.LESSER` for LGPL 2.1-or-later, BSD notices and the
unRAR restriction. The RAR decompression code may not be used to develop a
RAR-compatible compressor. The complete upstream source archive is distributed
alongside the executable as `7zip-26.06-src.tar.xz` and copied into the app's
`Resources/7zip/` directory. It is also available at the corresponding-source
URL above. 7-Zip is a separate command line program,
not linked into OneClick. Replacement compatible executables can be built from
that source; sign the replacement with the same empty entitlement set
and re-sign the app when replacing a bundled copy.

`7z.sfx` is the unmodified Windows x64 GUI self-extraction module from the
official 26.06 Windows installer. The app prepends it to a 7Z archive to produce
a Windows `.exe`; this module is data on macOS and is never executed by the app.
Its corresponding source is included in the source archive above (`CPP/7zip/Bundles/SFXWin`).

- Distribution: https://github.com/ip7z/7zip/releases/download/26.06/7z2606-x64.exe
- Installer SHA-256: `9b697f65ecc2d9b0152f5ee96d72dde522a7827690349d9307935dacf40f42ec`
- Module SHA-256: `73af2700392aa92bc9342ae63844dfeed157d8d68bd356326a9bddb5e9e312d7`
