# Finder compression and extraction

Select files or folders in Finder and choose **Compress…**. The window lets you
choose ZIP, 7Z or TAR.GZ, a compression level (Fastest, Fast, Normal or Maximum),
and optional password protection for ZIP and 7Z. Compression starts only when you
click **Compress**. Higher levels generally trade processing time for smaller
archives; the actual result depends on the input. Multiple selections are stored
together in one archive. Direct Finder shortcuts can create either ZIP or 7Z.
Choose **Compress to Separate ZIPs** or **Compress to Separate 7Zs** to create one
archive per selected file or folder beside its source, using the source's full name
(for example, `notes.txt.zip`). Existing names gain a numbered suffix. Each item
has its own progress result, so a failed item does not stop the rest of the batch.
The matching **and Delete Originals** shortcuts test the finished archive before
publishing it, then remove the selected sources only after verification succeeds.
These shortcuts use the same compression exclusions and CPU thread setting.
Select archives
and choose **Extract Here** to extract each into its own folder beside the archive.
Choose **Extract and Delete Archive** to delete each selected archive after its
contents have been extracted successfully. Failed or cancelled extraction keeps
the original archive. Password prompts and batch processing work the same way as
**Extract Here**. If deletion fails, the extracted folder remains available and
the window displays the deletion error.
These actions can be toggled and reordered in Settings → Compression & Extraction,
which also provides default format and compression level settings, a compression
CPU thread limit, an exclusion list, and an independent menu-collapse switch.
The direct ZIP/7Z/TAR.GZ compression shortcuts remain available there. Password
protection is configured through **Compress…**. Existing enabled/disabled choices
are preserved when the new Compress… action is added.
They require selected items; Finder's empty-space and toolbar menus disable them.

The operation window shows current activity, errors, and a
**Show in Finder** button for each completed result. **Cancel** closes the window.
Successful operations close automatically, including when **Verify After
Compression** is enabled. Verification failures keep the window open to show the
error; click **Done** to close it.
Closing the window cancels unfinished work. Folder authorization uses OneClick's
existing bookmark service.
Cancelling authorization never produces a partially selected compression archive.

## Compression exclusions and CPU threads

In Settings → Compression & Extraction, enable **Exclude matching files** and
edit the **Exclusion List**, one file or folder name pattern per line. Patterns
such as `.DS_Store`, `node_modules` and `*.tmp` apply at every folder level,
including explicitly selected items. Matching folders and their contents are
omitted. Empty lines and duplicate patterns are ignored. Exclusions default to
off; the initial list contains `.DS_Store` and `__MACOSX`. Disabling exclusions
retains the list. Extraction always restores the full archive contents.

**Compression CPU Threads** defaults to **Automatic** (the available logical CPU
count), or can be set from one to the available logical CPU count. ZIP and 7Z,
including encrypted archives, pass this limit to 7-Zip; actual CPU use depends
on the codec and input. TAR.GZ uses a single-threaded system gzip encoder.
Both settings apply to **Compress…** and the direct compression shortcuts.
**Restore Defaults** also resets these settings.

## Password protection

Choose **Compress…**, select ZIP or 7Z, enable **Password Protection**, enter a
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

## Split volumes and solid compression

In **Compress…**, enable **Split into Volumes** for ZIP or 7Z, including encrypted
archives. Choose **CD (700 MiB)**, **DVD (4.7 GB)**, **FAT32 (4 GiB − 1 B)**,
or **Custom Size** with a positive whole number in B, KiB, MiB or GiB. DVD uses
4,700,000,000 bytes; FAT32 uses 4,294,967,295 bytes to stay below its 4 GiB limit.
The size is the maximum per volume; the last volume can be smaller. Splitting is
off by default and is unavailable for TAR.GZ.

Volumes are created beside the selected items as `name.zip.001`, `name.zip.002`,
etc. (or `name.7z.001`, etc.). Keep the entire set together and choose
**Extract Here** on the `.001` file. **Show in Finder** selects this first volume.
Existing archives and volume sets, including incomplete sets, are preserved by
giving the new set a numbered name. Failed or cancelled jobs clean up their
staging directory and roll back volumes already moved into place.

For 7Z, **Solid Compression** is on by default, matching 7-Zip's default.
Disable it to compress files independently. Solid archives can be smaller when
files share content, but extracting an individual file may take longer. These
options apply to the current custom compression job; direct shortcuts retain
their existing behavior.

## Archive browser and file associations

**Toolbox → Compression & Extraction → Open Archive…** opens a dedicated browser.
Navigate folders, search paths across the archive, and select a file to preview.
The file table shows name, uncompressed size, modification time and creation time.
Click a column heading to sort ascending or descending; the same order applies
when navigating folders or searching. Folders stay first, equal values use natural
filename order, and unavailable times appear as **—** and sort last. Times are
read from archive metadata; formats that do not store creation times leave them
unavailable. Hover over a size or time to see the exact byte count or full date.
Text up to 2 MiB is shown in a selectable text pane, images display inline, and
**Quick Look** opens the system preview for PDF and other supported formats.
Preview content is limited to 64 MiB, including incorrectly declared sizes.
**Extract All…** uses the existing extraction workflow with destination
authorization and collision protection.

Under **File Associations**, select ZIP, 7Z, RAR, TAR or TGZ and click
**Associate Selected Formats**. macOS may request consent. Launching OneClick
does not change default handlers. Double-clicking an associated file opens its
browser, including when OneClick was not running. Current associations and errors
are shown in settings. To change back, use Finder's Get Info → Open with →
Change All. macOS may classify `.tar.gz` as GZIP rather than TGZ; use
**Open Archive…** or Finder's Open With for these files.

7Z/RAR and split-volume listings use bundled 7-Zip. ZIP, TAR filters and other
libarchive formats use the macOS libarchive directory reader, preserving Unicode
and embedded newlines in names. ZIP/7Z/RAR previews use 7-Zip; other previews use
libarchive. Listings are bounded to 100,000 entries and 32 MiB
of names/listing output. Missing folder records are synthesized. Encrypted
headers prompt before listing; encrypted contents prompt when previewing.
Passwords stay in window memory and clear when the window closes.

Directory indexing, sorting, search, preview file writes and image decoding run
off the UI thread. Folder navigation uses a cached directory index, and text
previews use a native text view that lays out visible content on demand.

Only the selected entry is read for preview. Archive paths never become
filesystem destinations. Preview bytes go to a generated file in a private
mode-0700 temporary directory, removed when replaced or the window closes.
Links, duplicate paths and traversal paths cannot be previewed. 7-Zip wildcard
matching is disabled for exact-name selection. Closing a browser or selecting
another file cancels pending work. Browsing does not write beside the archive.

## Implementation

Keka's [current repository](https://github.com/aonez/Keka) provides documentation,
translations, binaries and issue tracking rather than the complete application
source. This implementation is independent; it does not copy Keka code or require
Keka to be installed.

`ArchiveService` uses Apple's `/usr/bin/tar` (bsdtar/libarchive) for TAR.GZ and
TAR-family extraction. An unmodified, bundled official
7-Zip 26.05 universal macOS executable handles configurable ZIP/7Z compression,
encrypted compression and ZIP/7Z/RAR
extraction. Each is launched by `Process` with separate arguments and no shell.
The host and helper run without App Sandbox or sandbox-inheritance entitlements. Operations run off
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
  codecs fail with a visible diagnostic. ZIP/7Z split sets created by OneClick can
  be extracted from their `.001` file. RAR creation and other split-volume naming
  conventions are not offered. TAR.GZ does not support passwords or split volumes.
- Single-file GZIP/BZIP2/XZ streams without a TAR container are not offered by
  this version. Disk images such as DMG should be opened with macOS.

## Verification

`ArchiveServiceTests` exercises real archives, content round trips, unusual names,
destination collisions, cancellation, corrupt input and adversarial archive paths,
AES ZIP encryption, Unicode 7Z passwords, encrypted 7Z headers, and upstream
libarchive RAR4/RAR5 encrypted-data and encrypted-header fixtures.
`ArchiveViewModelTests` checks password gating and retries across mixed batches.
Split-volume tests verify size limits, encrypted round trips, collision handling,
concurrent jobs and cancellation; 7Z listings verify the solid compression switch.
`ActionServiceTests` checks authorization and selection dispatch.
`ConfigServiceSaveTests` checks migration and preservation of disabled actions.
