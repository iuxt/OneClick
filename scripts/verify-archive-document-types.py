#!/usr/bin/env python3
"""Reject app builds that cannot receive associated archive documents."""
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
expected = {
    "public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
    "public.tar-archive", "org.gnu.gnu-zip-tar-archive",
}
declared = {
    type_id
    for document in info.get("CFBundleDocumentTypes", [])
    if document.get("CFBundleTypeRole") == "Viewer"
    for type_id in document.get("LSItemContentTypes", [])
}
missing = expected - declared
if missing:
    sys.exit("Archive document declarations missing; installation cancelled: " + ", ".join(sorted(missing)))

imported = {
    declaration.get("UTTypeIdentifier")
    for declaration in info.get("UTImportedTypeDeclarations", [])
    if declaration.get("UTTypeTagSpecification", {}).get("public.filename-extension")
}
missing = (expected - {"public.zip-archive"}) - imported
if missing:
    sys.exit("Archive type extensions missing; installation cancelled: " + ", ".join(sorted(missing)))
print("PASS: archive document types and filename extensions included in app bundle")
