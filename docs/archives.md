# Finder compression and extraction

Select files or folders in Finder and choose **Compress…**. The window lets you
choose ZIP, 7Z or TAR.GZ, a compression level (Fastest, Fast, Normal or Maximum),
and optional password protection for ZIP and 7Z. Compression starts only when you
click **Compress**. Higher levels generally trade processing time for smaller
archives; the actual result depends on the input. Multiple selections are stored
together in one archive. Select archives
and choose **Extract Here** to extract each into its own folder beside the archive.
These actions can be toggled and reordered in Settings → Compression & Extraction,
which also provides default format and compression level settings, and an
independent menu-collapse switch. The existing direct ZIP/TAR.GZ and encrypted
compression shortcuts remain available there. Existing enabled/disabled choices
are preserved when the new Compress… action is added.
They require selected items; Finder's empty-space and toolbar menus disable them.

The operation window shows current activity, errors, and a
**Show in Finder** button for each completed result. **Cancel** closes the window.
Closing the window cancels unfinished work. Folder authorization uses RClick's
existing bookmark service.
Cancelling authorization never produces a partially selected compression archive.

## Password protection

Choose **Compress to Encrypted ZIP…** or **Compress to Encrypted 7Z…**, enter a
password twice and create the archive. Both use AES-256. ZIP encrypts file contents
while leaving names visible; 7Z also encrypts file names. ZIP creation accepts
1–99 printable ASCII characters because of the upstream 7-Zip ZIP writer's
restrictions. Use encrypted 7Z for Chinese or other Unicode passwords.

**Extract Here** detects encrypted ZIP (AES or traditional ZipCrypto), 7Z, RAR4
and RAR5 archives, including encrypted headers. The window requests a password
and allows retry after an incorrect one. Other files in the batch continue;
completed results remain available. Passwords are never saved in requests,
settings, files, environment variables or process arguments. A private stdin pipe
passes each password to the bundled tool. The password fields clear on submission.
Passwords containing line breaks or null characters, or exceeding 1,024 UTF-8
bytes, are rejected. Archives using different passwords for individual entries
are not supported by this single-password workflow.

## Implementation

Keka's [current repository](https://github.com/aonez/Keka) provides documentation,
translations, binaries and issue tracking rather than the complete application
source. This implementation is independent; it does not copy Keka code or require
Keka to be installed.

`ArchiveService` uses Apple's `/usr/bin/tar` (bsdtar/libarchive) for TAR.GZ and the
direct ZIP shortcut, and TAR-family extraction. An unmodified, bundled official
7-Zip 26.05 universal macOS executable handles configurable ZIP/7Z compression,
encrypted compression and ZIP/7Z/RAR
extraction. Each is launched by `Process` with separate arguments and no shell.
The helper is signed with sandbox-inheritance entitlements. Operations run off
the main actor and stream bounded diagnostic output. File data is handled by the
tools, not buffered in Swift memory. The build includes the 7-Zip licenses and
complete corresponding source archive under `Contents/Resources/7zip/`.

Output is staged in a randomly named, mode-0700 directory beside the source and
moved into place only on success. Existing output is never replaced: names gain
` (2)`, ` (3)`, etc. Failed and cancelled jobs remove their staging directories.
Original files are retained. Extraction keeps bsdtar's default protections against
`..` traversal and writing through symlinks; `-P` is never used. 7-Zip runs with
`-snld0` to reject dangerous symlinks and without `-spf` (absolute paths). Path
traversal fixtures exercise both backends. TAR extraction does not restore
ownership, ACLs, extended attributes, file flags or privileged permissions.

## Supported scope

- Create ZIP and gzip-compressed PAX/TAR archives, including nested folders,
  empty folders, hidden files, and symbolic links without following them.
- Create ordinary 7Z archives and configure compression levels for ZIP, 7Z and TAR.GZ.
- Create AES-256 encrypted ZIP and 7Z archives. The latter encrypts headers too.
- Recognize ZIP/ZIPX, 7Z, RAR, TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2, TAR.XZ/TXZ,
  TAR.LZMA, TAR.Z, JAR, WAR, APK, IPA, XPI, CAB, ISO, CPIO and CPGZ.
- TAR-family extraction codecs depend on the libarchive version shipped with
  macOS; ZIP/7Z/RAR use the bundled 7-Zip version. Damaged archives or unsupported
  codecs fail with a visible diagnostic. Split-volume handling and RAR creation
  are not offered by this version. TAR.GZ does not support passwords.
- Single-file GZIP/BZIP2/XZ streams without a TAR container are not offered by
  this version. Disk images such as DMG should be opened with macOS.

## Verification

`ArchiveServiceTests` exercises real archives, content round trips, unusual names,
destination collisions, cancellation, corrupt input and adversarial archive paths,
AES ZIP encryption, Unicode 7Z passwords, encrypted 7Z headers, and upstream
libarchive RAR4/RAR5 encrypted-data and encrypted-header fixtures.
`ArchiveViewModelTests` checks password gating and retries across mixed batches.
`ActionServiceTests` checks authorization and selection dispatch.
`ConfigServiceSaveTests` checks migration and preservation of disabled actions.
