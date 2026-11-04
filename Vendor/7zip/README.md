# Bundled 7-Zip command line tool

Unmodified official 7-Zip 26.05 for macOS (2026-10-21), universal arm64/x86_64.
The app invokes this separate executable for encrypted ZIP/7Z creation and
ZIP/7Z/RAR extraction. It requires no external installation or network access.

- Project: https://www.7-zip.org/
- Binary distribution: https://github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz
- Corresponding source: https://github.com/ip7z/7zip/releases/download/26.05/7z2605-src.tar.xz
- Source repository/tag: https://github.com/ip7z/7zip/tree/26.05
- Binary archive SHA-256: `12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570`
- Original universal executable SHA-256: `8e495531e1b2b8cb169ca583493922d4ab386007756418c15b95f07f642c35fb`

The build copies `7zz` into `OneClick.app/Contents/Helpers/` and signs the copy with
`7zz.entitlements` to inherit the parent's sandbox. Signing changes the hash of
the app-bundled copy; the vendored file remains the upstream binary.

See `License.txt` and `COPYING.LESSER` for LGPL 2.1-or-later, BSD notices and the
unRAR restriction. The RAR decompression code may not be used to develop a
RAR-compatible compressor. The complete upstream source archive is distributed
alongside the executable as `7zip-26.05-src.tar.xz` and copied into the app's
`Resources/7zip/` directory. It is also available at the corresponding-source
URL above. 7-Zip is a separate command line program,
not linked into OneClick. Replacement compatible executables can be built from
that source; sign the replacement with the same inherited-sandbox entitlements
and re-sign the app when replacing a bundled copy.
