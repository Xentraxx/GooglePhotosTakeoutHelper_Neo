# Troubleshooting

## ExifTool warnings and errors during Step 7 (Write EXIF Data)

You may see a large number of warnings or errors in your log during Step 7, such as:

```
Error: Bad format (282) for InteropIFD entry 0 - /path/to/your/photo.jpg
Error: Truncated InteropIFD directory - /path/to/your/photo.jpg
[WARNING] [ExifToolService] ExifTool command failed with exit code 1.
[WARNING] [ExifToolService] Failed to write tags: [OffsetTime, OffsetTimeOriginal, ...] to ...
```

**These warnings are not a sign that something went seriously wrong.** Here is what is actually happening and why you can safely ignore them.

### What the errors mean

These errors all point to corruption in the EXIF metadata of your image file, specifically in the **InteropIFD** and **IFD1** (thumbnail) sections.

**InteropIFD** is a small sub-directory inside EXIF that stores interoperability tags (like R98 for sRGB or THM for DCF thumbnails). It is referenced by an offset pointer from the main EXIF IFD.

| Error | Meaning |
|-------|---------|
| `Bad InteropIFD offset for Exif_0x0000` | The pointer that should point to the InteropIFD block contains an invalid value — it is either zero, out of bounds, or points into garbage data. This is usually the root cause of all the errors below it, since once the offset is wrong, everything read from that location is meaningless. |
| `Bad format (1280/1377/1378/282) for InteropIFD entry 0` | Each IFD entry has a 2-byte field type (1=BYTE, 2=ASCII, 3=SHORT, etc. — valid types go up to ~13). Values like 1280, 1377, 1378 are completely invalid type codes, meaning ExifTool is reading random bytes that are not actually IFD entries. The 282 case is a bit special — tag 0x011A (decimal 282) is XResolution, which is a valid tag number but not a valid field type, so it was likely misread as a type due to the bad offset. |
| `Truncated InteropIFD directory` | After following the bad offset, ExifTool ran out of file data before it could read the expected number of IFD entries. The directory is either pointing past the end of the file or into a much smaller region than expected. |
| `Error reading ThumbnailImage data in IFD1` | IFD1 stores the embedded JPEG thumbnail. Its offset/length pointers are likely also corrupted (or shifted), so ExifTool cannot read the thumbnail bytes. This often happens together with InteropIFD corruption when a write operation partially failed and scrambled the EXIF block. |

### Why does this happen?

The images are not corrupted by GPTH. They arrived this way from Google Photos. Some apps — such as **WhatsApp** or the **Google Photos editor** (images with the `-edited` suffix) — write data into the InteropIFD in a non-standard, broken way. When ExifTool tries to work with that section, it refuses, because from its perspective the structure is malformed.

### What actually gets written?

GPTH uses a multi-strategy approach. When InteropIFD errors occur, it retries the write **without** the UTC timezone offset tags (`OffsetTime*`). The core data — **dates and GPS coordinates** — are written successfully. Only the UTC timezone offset metadata cannot be embedded, because that is stored in the InteropIFD.

If you see this specific warning, it means the date was written and the file is organised correctly — only the UTC offset is missing:

```
[Step 7/8] photo.jpg: UTC timezone offset (+00:00) metadata could not be embedded —
corrupted EXIF structure (InteropIFD). The date itself was already written and the
file is organised correctly.
```

### Can this be fixed?

The only way to fix the underlying corruption would be to completely wipe the existing EXIF data and start fresh. However, that would also wipe fields that GPTH does not touch — camera model, aperture, focal length, etc. — which is an unacceptable trade-off. The corrupted sections (InteropIFD, IFD1 thumbnail) are widely ignored by modern software anyway, so there is no practical impact on how the files behave in photo viewers or libraries.

**Bottom line: if you only see InteropIFD / IFD1 errors, your files are fine.** Dates and GPS coordinates were written successfully.
