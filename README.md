# Google Photos Takeout Helper Neo 📸

[![Downloads](https://img.shields.io/github/downloads/Xentraxx/GooglePhotosTakeoutHelper_Neo/total?label=downloads)](https://github.com/Xentraxx/GooglePhotosTakeoutHelper_Neo/releases/)
[![Issues](https://img.shields.io/github/issues-closed/Xentraxx/GooglePhotosTakeoutHelper_Neo?label=resolved%20issues)](https://github.com/Xentraxx/GooglePhotosTakeoutHelper_Neo/issues)

Transform your chaotic Google Photos Takeout into organized photo libraries with proper dates, albums, and metadata.

**Acknowledgment**: This project is based on the original work by [TheLastGimbus](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper). We are grateful for their foundational contributions to the Google Photos Takeout ecosystem.
Also thank you to @jaimetur for your significant contributions to this fork!

**Important temporary note**: The  `--transform-pixel-mp` modes are pretty broken and still work in progress, so I recommend not using them for the time being. I will look into that at a later date. Pull requests which fix the reported issues are welcome.

## What This Tool Does

When you export photos from Google Photos using [Google Takeout](https://takeout.google.com/), you get a mess of folders with weird `.json` files, broken timestamps and many many edge cases like truncated file names etc.

This tool fixes and organises everything.

### Why Use This Fork? Main Benefits Over GooglePhotosTakeoutHelper & immich-go

**This tool addresses real pain points users face with other solutions, and adds unique features for a safer, more reliable migration:**

- **Works with all Google Takeout exports**: No need to set your Google account language to English. Handles non-English exports and normalizes folder names (even with hidden Unicode spaces) so no photos are missed (You can check the supported languages here: [constants.dart](https://github.com/Xentraxx/GooglePhotosTakeoutHelper_Neo/blob/master/lib/common/constants/constants.dart).
- **Preserves all your data**: Album-only photos, RAW files, and special folders (Archive, Locked Folder, etc.) are processed or clearly reported. No silent skipping or accidental data loss.
- **Flexible album handling**: Multiple strategies (shortcuts, hardlinks, JSON, etc.) with safe defaults and clear documentation. You choose how albums are organized.
- **Advanced duplicate detection**: Detailed logs show exactly which files are skipped or merged. If any operation fails for a certain file, it is transparent.
- **Superior EXIF and metadata restoration**: Recovers missing timestamps and GPS/location data in your media files.
- **Smart extension and format fixing**: Automatically corrects mismatches between file extensions and actual content (e.g., .heic files that are really JPEGs), preventing failures in downstream tools. Skips RAW/TIFF files safely.
- **Motion Photo & special format support**: Handles Pixel Motion Photos (.MP, .MV) and sidecar files intelligently, avoiding unnecessary warnings or useless uploads.
- **User-friendly error handling**: Actionable error messages and troubleshooting tips for common issues (permissions, missing dependencies, etc.).
- **Safer migration**: Ensures all files are processed or clearly reported if skipped, reducing risk of accidental data loss.

#### Pain Points Solved (Compared to Other Tools)

- No more missing photos due to non-standard folder names or non-English exports (common in GooglePhotosTakeoutHelper)
- No more unexplained process failures or cryptic logs (common in immich-go)
- No more silent skipping of RAW, album-only, or special-folder files
- No more ambiguous duplicate detection. Logs are clear and actionable
- No more files uploaded without extensions or missing metadata.

**In short:** This tool is designed for reliability, transparency, and maximum data preservation—solving the real-world problems users report with other migration tools.
**Note**: This tool moves files by default to avoid using extra disk space. Always keep backups of your original Takeout files!

Please note the [wiki](https://github.com/Xentraxx/GooglePhotosTakeoutHelper/wiki) is not yet complete but contains more technical details if you are looking for more information about how everything works. Contributions are welcome!

## Installation & Setup

### 1. Download GPTH

Download the latest executable from [releases](https://github.com/Xentraxx/GooglePhotosTakeoutHelper/releases)

**Building from Source:**
```bash
git clone https://github.com/Xentraxx/GooglePhotosTakeoutHelper.git
cd GooglePhotosTakeoutHelper
dart pub get
dart compile exe bin/gpth.dart -o gpth
```

### 2. Install Prerequisites

**ExifTool** (required for metadata handling):

- **Windows**:
  ```bash
  # With Chocolatey (automatically adds to PATH):
  choco install exiftool

  # Or with winget (automatically adds to PATH):
  winget install OliverBetz.ExifTool
  ```
  - Or download from [exiftool.org](https://exiftool.org/) and rename `exiftool(-k).exe` to `exiftool.exe`
  - Place `exiftool.exe` in your system PATH, or place it in the same folder as `gpth.exe`
  - Also place the `exiftool_files` folder next to `gpth.exe`
- **Mac**: 
  ```bash
  brew install exiftool
  ```
  - Or download from [exiftool.org](https://exiftool.org/) and place `exiftool` in PATH or same folder as `gpth`
- **Linux**: 
  ```bash
  sudo apt install libimage-exiftool-perl
  ```
  - Or download from [exiftool.org](https://exiftool.org/) and place `exiftool` in PATH or same folder as `gpth`

**Note**: If ExifTool is not found in PATH or the same directory as GPTH, the tool will fall back to basic EXIF reading with limited format support. EXIF writing for non-JPEG formats requires ExifTool.

**7-Zip** (optional — faster for for automatic ZIP extraction):

GPTH can extract your Google Takeout ZIP files automatically if 7-Zip is available on your system.

- **Windows**:
  ```bash
  # With Chocolatey (automatically adds to PATH):
  choco install 7zip

  # Or with winget (automatically adds to PATH):
  winget install 7zip.7zip
  ```
  - Or download the installer from [7-zip.org](https://www.7-zip.org/) and install it
  - After installation, ensure `7z.exe` is in your system PATH, or place it in the same folder as `gpth.exe`
- **Mac**:
  ```bash
  brew install sevenzip
  ```
  - Or download from [7-zip.org](https://www.7-zip.org/download.html)
- **Linux**:
  ```bash
  sudo apt install 7zip
  ```

**Note**: If 7-Zip is not found, GPTH will fall back to Dart's built-in ZIP extractor. The built-in extractor is significantly slower for very large archives.

## Quick Start

### 1. Get Your Photos from Google Takeout

1. Go to [Google Takeout](https://takeout.google.com/takeout/custom/photos)
2. Click "next step"
3. Choose "ZIP" and "50GB" and click on "Create export" (if you choose 2GB and you have e.g. videos larger than 2GB, they will be exported in an unsupported way)
4. Wait for it to finish and then download all zip files.

### 2. Choose Your Extraction Method

GPTH now supports automatic extraction directly from ZIP files:

#### Option A: Automatic ZIP Processing (Recommended)
1. Keep your ZIP files from Google Takeout
2. When running GPTH in interactive mode, select "Select ZIP files from Google Takeout"
3. GPTH will automatically extract, merge, and process all files
4. Original ZIP files are preserved; temporary extracted files are cleaned up automatically

The automatic ZIP processing is recommended for most users as it:
- Reduces manual work and potential errors
- Ensures proper file merging across multiple ZIP files
- Automatically cleans up temporary files

The biggest downside is, that you need the processing power to extract on the device you run gpth. If this is an issue, choose manual extraction.

#### Option B: Manual Extraction (Traditional)
1. Unzip all files manually
2. Merge them so you have one unified "Takeout" folder
3. When running GPTH, select "Use already extracted folder"

<img width="75%" alt="Unzip image tutorial" src="https://user-images.githubusercontent.com/40139196/229361367-b9803ab9-2724-4ddf-9af5-4df507e02dfe.png">

**⚠️ Note that the files will be moved from the input folder during processing, so keep the original ZIPs as backup!**

### 3. Run GPTH

**Interactive Mode** (recommended for beginners or non-technical users):
- Windows: Double-click `gpth.exe`
- Mac/Linux: Run `./gpth-macos` or `./gpth-linux` in terminal

Follow the prompts to select input/output folders and options

## Album Handling Options

GPTH offers several ways to handle your Google Photos albums:

By default, non-album photos are written under `ALL_PHOTOS`. You can customize this folder name (or remove this extra level entirely) with `--all-photos-dir`.

> [!NOTE]
> **Special folders** (`Archive`, `Trash`, `Locked Folder`, etc.) are **always** moved to `output/Special Folders/<Name>/` regardless of the album mode chosen. None of the strategies below affect them.

### 1. 🔗 Shortcut (Recommended)
**What it does:** Creates symbolic links from album folders to files in `ALL_PHOTOS`. The original files are moved to `ALL_PHOTOS`, and symlinks are created in album folders.

`Windows only:` Add `--hardlink` to create hard links instead of symlinks for this mode.

**Advantages:**
- Saves maximum disk space (no duplicate files)
- Maintains album organization
- Fast processing
- Better compatibility with cloud services and file type detection
- Works across all platforms (Windows, Mac, Linux)

**Disadvantages:**
- Requires symbolic link support (most modern systems support this)
- Some older applications may not follow symlinks properly
- With `--hardlink`, links must be on the same Windows volume/drive

**Best for:** Most users who want space efficiency and better compatibility with modern applications and cloud services.

### 2. 🔄 Reverse Shortcut
**What it does:** The opposite of shortcut mode. Files remain in their original album folders, and shortcuts are created in `ALL_PHOTOS` pointing to the album locations.

`Windows only:` Add `--hardlink` to create hard links instead of symlinks for this mode.

**Advantages:**
- Preserves album-centric organization
- Original files stay in their natural album context
- Good for users who primarily browse by albums

**Disadvantages:**
- `ALL_PHOTOS` becomes dependent on album folders
- If a photo is in multiple albums, only one copy exists (in first album found)
- Shortcuts in `ALL_PHOTOS` may break if album folders are moved
- With `--hardlink`, links must be on the same Windows volume/drive

**Best for:** Users who primarily organize and browse photos by albums rather than chronologically.

### 3. 📁 Duplicate Copy
**What it does:** Creates actual file copies in both `ALL_PHOTOS` and album folders. Each photo appears as a separate physical file in every location.

**Advantages:**
- Works across all systems and applications
- Complete independence between folders
- Safe for moving/copying folders between devices
- Album photos remain accessible even if `ALL_PHOTOS` is deleted

**Disadvantages:**
- ⚠️ Uses significantly more disk space (multiplied by number of albums)
- Slower processing due to file copying
- Changes to one copy don't affect others

**Best for:** Users who need maximum compatibility, plan to share folders across different systems, or have plenty of disk space.

### 4. 📄 JSON
**What it does:** Creates a single `ALL_PHOTOS` folder with all files, plus an `albums-info.json` file containing metadata about which albums each file belonged to.

**Advantages:**
- Most space-efficient option
- Programmatically accessible album information
- Simple folder structure
- Perfect for developers or automated processing

**Disadvantages:**
- No visual album folders
- Requires custom software to utilize album information
- Not user-friendly for manual browsing

**Best for:** Developers, users migrating to photo management software that can read JSON metadata, or those who don't care about visual album organization.

### 5. ❌ Nothing
**What it does:** Doesn't create `Albums` folder. All photos from each album and from year folders are moved to `ALL_PHOTOS` with all files organized chronologically. All files are moved to `ALL_PHOTOS` regardless of their source location. If one file belong to more than 1 albums, then only 1 copy will be kept in `ALL_PHOTOS`

**Advantages:**
- Simplest processing
- Fastest execution
- Clean, single-folder result
- No complex album logic
- No data loss - all files are moved

**Disadvantages:**
- ⚠️ Completely loses album organization
- ⚠️ No way to recover album information later

**Best for:** Users who don't care about album organization and just want all photos in chronological order.

### 6. 🗑️ Ignore Albums
**What it does:** Ignores albums entirely and creates only `ALL_PHOTOS` with files from year folders (`Photos from YYYY`) organized chronologically. Album folders are ignored: files that exist only in album folders (and not in any year folder) are **permanently deleted from disk** and will not appear anywhere in the output.

> [!WARNING]
> **This mode causes permanent data loss.** Any photo or video that exists exclusively inside an album folder — including untitled/unknown albums — will be **deleted and cannot be recovered**. This includes files in named albums, untitled albums (`untitled`, `unknown`, etc.), and any album-only content. Only files that also appear in a `Photos from YYYY` year folder are preserved.

**Advantages:**
- Simplest processing
- Fastest execution
- Clean, single-folder result

**Disadvantages:**
- ⚠️ **Permanently deletes all album-only files** — these are gone forever
- ⚠️ Completely loses album organization
- ⚠️ No way to recover album-only content after running

**Best for:** Users who are certain all their photos exist in year folders and simply want to skip album processing entirely.


## Important Notes

> [!IMPORTANT]  
> - **File Movement:** GPTH moves files from the input to output directory to save space. Files are moved, not copied, which means the input directory structure will be modified as files are relocated.
> - **Album-Only Photos:** Some photos exist only in albums (not in year folders). GPTH handles these differently depending on the mode chosen.
> - **Duplicate Handling:** If a photo appears in multiple albums, the behavior varies by mode (shortcuts link to same file, duplicate-copy creates multiple copies, etc.).

## Command Line Usage

For automation, headless systems, or advanced users:

```bash
gpth --input "/path/to/takeout" --output "/path/to/organized" --albums "shortcut"
```

### Core Arguments

| Argument         | Description                                                                                   |
|------------------|-----------------------------------------------------------------------------------------------|
| `--input`, `-i`  | Input folder containing extracted Takeout or your unextracted zip files                       |
| `--output`, `-o` | Output folder for organized photos                                                            |
| `--albums`       | Album handling: `shortcut`, `duplicate-copy`, `reverse-shortcut`, `json`, `nothing`, `ignore` |
| `--hardlink`     | Windows only: for `shortcut` and `reverse-shortcut`, create hard links instead of symlinks (same drive required) |
| `--keep-input`   | Work on a temporary sibling copy of --input (suffix _tmp), keeping the original untouched     |


### Organization Options

| Argument                  | Description                                                                                                                                          |
|---------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--divide-to-dates`       | Date-based folder structure for the non-album output folder: `0`=one folder, `1`=by year, `2`=year/month, `3`=year/month/day (albums remain flattened) (default: `2`) |
| `--all-photos-dir`        | Custom name for the non-album output folder (default: `ALL_PHOTOS`). Set to `""` to remove the extra folder level and place dated folders directly under output |
| `--divide-partner-shared` | Separate partner shared media into a dedicated `PARTNER_SHARED` folder (works with date division)                                                    |
| `--skip-extras`           | Skip extra images like "-edited" versions                                                                                                            |
| `--keep-duplicates`       | Keeps all duplicates files found in `_Duplicates` subfolder within in output folder instead of remove them totally                                   |

### Metadata & Processing

| Argument                 | Description                                                                                                               |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `--write-exif`           | Write GPS coordinates and dates to EXIF metadata (enabled by default)                                                     |
| `--transform-pixel-mp`   | Transform Pixel Motion Photos (.MP/.MV) to `mp4`, `jpg`, or `still` (example: `--transform-pixel-mp jpg`)                 |
| `--guess-from-name`      | Extract dates from filenames (enabled by default)                                                                         |
| `--update-creation-time` | Sync creation time with modified time (Windows only)                                                                      |
| `--limit-filesize`       | Skip files larger than 64MB (for low-RAM systems)                                                                         |
| `--json-dates`           | Provide a JSON dictionary with the dates per file to avoid reading it from EXIF when any file does not associated sidecar |
| `--no-resume`            | Discard any saved progress from a previous run (`progress.json` in the output folder) and always start fresh (resume is enabled by default) |

> The `--json-dates` argument should be a JSON dictionary that must have as key the full filepath (in unix format) and the value must be a dictionary with at least the key `oldestDate` which contains the date for the given filepath.  
>
> Example:
> ```
> {
>   "/data/2012-08-05_161346-EFFECTS.jpg": {
>     "OldestDate": "2012-08-05T00:00:00+02:00"
> 
>   },
>   "/data/2012-08-07_090832.JPG": {
>     "OldestDate": "2012-08-05T15:42:06+02:00"
> }
> ```

### Pixel Motion Photo Transform

#### Background: What is a Pixel Motion Photo?

Google Pixel cameras produce **motion photos**: a single `.MP` or `.MV` file that contains a short MP4 video clip with a JPEG still image embedded inside it. Google Photos typically exports a companion `*.MP.jpg` sidecar (the still image as a separate file) alongside the `.MP` container, but this sidecar is not always present.

Without this flag, GPTH leaves `.MP`/`.MV` files as-is (they are valid video containers and will open in any media player). The flag lets you convert them into a format that better suits your photo library.

#### Mode Overview

| Flag value | What you get | Video kept? | Still image kept? |
|---|---|---|---|
| *(omitted)* | `.MP`/`.MV` left unchanged | ✅ | ✅ (sidecar `.jpg` if present) |
| `mp4` | `.MP`/`.MV` renamed to `.mp4` | ✅ | ✅ (sidecar `.jpg` if present) |
| `jpg` | Motion `.jpg` — still + embedded video in one file | ✅ | ✅ (merged into output `.jpg`) |
| `still` | Plain `.jpg` still image only | ❌ | ✅ |

#### `--transform-pixel-mp mp4` — Simple rename

Renames `.MP`/`.MV` files to `.mp4`. The file content is not changed. A companion sidecar `.jpg` (still image), if present, is left alongside the video as a separate file.

**Best for:** Users who want to preserve the video clip and just need a recognisable extension so media players detect it correctly.

#### `--transform-pixel-mp jpg` — Motion JPEG

Merges the still image and the video clip into a single **motion JPEG** — a standard JPEG with the MP4 stream embedded at the end. This is the native format used by Pixel phones for sharing motion photos, and it is understood by Google Photos, Samsung Gallery, and other apps that support Google's motion photo standard.

How the still image is sourced (in order of preference):
1. A plain `.jpg` sidecar next to the `.MP` file (e.g. `PXL_20230101.jpg`) — used directly as the still.
2. A motion-photo sidecar (e.g. `PXL_20230101.MP.jpg`) — the embedded JPEG is extracted from it.
3. No sidecar — the embedded JPEG is extracted directly from the `.MP` container.

Album symlinks/shortcuts for the converted file will use the `.jpg` extension.

**Best for:** Users who want motion photos that play back in Google Photos or Samsung Gallery after import, with no loss of the video clip.

#### `--transform-pixel-mp still` — Plain still image

Discards the video clip and produces a clean, plain `.jpg` still image. The output file has no embedded video and no motion-photo XMP markers, so it is indistinguishable from a regular photo.

How the still image is sourced (in order of preference):
1. A plain `.jpg` sidecar next to the `.MP` file (e.g. `PXL_20230101.jpg`) — used directly.
2. A motion-photo sidecar (e.g. `PXL_20230101.MP.jpg`) — the embedded JPEG is extracted and XMP motion markers are stripped.
3. No sidecar — the embedded JPEG is extracted from the `.MP` container and XMP motion markers are stripped.

If the `.MP` file contains no extractable JPEG at all (rare pure-video containers), it is renamed to `.mp4` as a fallback so the video is not silently lost.

**Best for:** Users who want the smallest, most compatible output and have no interest in the video component.

#### Apple Live Photos (HEIC + MP4)

Apple Live Photos exported from Google Takeout arrive as a `.HEIC` file and a same-stem `.MP4` file in the same folder. GPTH always passes both files through as separate files, regardless of the `--transform-pixel-mp` mode selected. No merging or suppression of Apple Live Photo pairs occurs.

### Extension Fixing Modes

Google Photos has the "Storage Saver" option, which will compress images to JPEG format but retain the original filename extension. Additionally, some web-downloaded images may have incorrect extensions (e.g., a file named `.jpeg` may actually be `.heif` internally).

GPTH natively writes EXIF data to files with JPEG signatures, while other formats require ExifTool. Files with mismatched extensions will cause ExifTool to fail, so GPTH provides several extension fixing strategies.

You can configure extension fixing behavior with:

| Argument                        | Description                                           | Technical Details                                                                                                                                                   | When to Use                                                                                                   |
|---------------------------------|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| `--fix-extensions=none`         | **Disable extension fixing entirely**                 | Files keep their original extensions regardless of content type. EXIF writing may fail for mismatched files.                                                        | When you're certain all extensions are correct, or when you want to preserve original filenames at all costs. |
| `--fix-extensions=standard`     | **Default: Fix extensions but skip TIFF-based files** | Renames files where extension doesn't match MIME type, but avoids TIFF-based formats (like RAW files from cameras) which are often misidentified by MIME detection. | **Recommended for most users**. Balances safety with effectiveness. Good for typical Google Photos exports.   |
| `--fix-extensions=conservative` | **Skip both TIFF-based and JPEG files**               | Most cautious approach - only fixes clearly incorrect extensions while avoiding both TIFF formats AND actual JPEG files to prevent any potential issues.            | When you have valuable photos and want maximum safety, or when you've had issues with previous modes.         |
| `--fix-extensions=solo`         | **Fix extensions then exit immediately**              | Performs extension fixing as a standalone operation without running the full GPTH processing pipeline. Useful for preprocessing files before the main operation.    | When you want to fix extensions first, then run GPTH again, or when integrating with other tools.             |

#### Why These Modes Exist

**The TIFF Problem**: Many RAW camera formats (CR2, NEF, ARW, etc.) are based on the TIFF specification internally. Standard MIME type detection often identifies these as `image/tiff`, which could cause the tool to rename `photo.CR2` to `photo.CR2.tiff`, potentially breaking camera software compatibility. This is why renaming `image/tiff` is excluded by default.

**ExifTool Dependencies**: When extensions don't match content, ExifTool operations fail. The extension fixing resolves this by ensuring filenames accurately reflect file content, enabling proper metadata writing.


#### Practical Examples

**Scenario 1: Google Photos Storage Saver**
- Original file: `vacation_sunset.heic` (HEIC format from iPhone)
- Google Photos compresses it to JPEG but keeps name: `vacation_sunset.heic`
- File header shows: JPEG, Extension suggests: HEIC
- `standard` mode renames to: `vacation_sunset.jpg`

**Scenario 2: Camera RAW File**
- Camera file: `DSC_0001.NEF` (Nikon RAW)
- MIME detection might identify as: TIFF (since NEF is TIFF-based)
- `standard` mode: **Skips** (protects RAW files)
- `conservative` mode: **Skips** (protects RAW files)
- `none` mode: **No change** (leaves as-is)

**Scenario 3: Web Download**
- Downloaded as: `image.png`
- Actually contains: JPEG data
- `standard` mode renames to: `image.jpg`
- `conservative` mode: **Skips** (avoids touching JPEG content)

### Other Options

| Argument           | Description                                              |
|--------------------|----------------------------------------------------------|
| `--interactive`    | Force interactive mode                                   |
| `--save-log`, `-l` | Save a log file into output folder (enabled by default)  |
| `--verbose`, `-v`  | Show detailed logging output                             |
| `--fix`            | Special mode: fix dates in any folder (not just Takeout) |
| `--help`, `-h`     | Show help and exit                                       |

### Example Commands

**Basic usage:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --albums "shortcut"
```

**Move files with year folders:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --divide-to-dates 1
```

**Full metadata processing:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --transform-pixel-mp jpg --albums "duplicate-copy"
```

**Separate partner shared media with date organization:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --transform-pixel-mp jpg --divide-partner-shared --divide-to-dates 1
```

**Fix dates in existing folder:**
```bash
gpth --fix "~/existing-photos"
```

## Features & Capabilities

### 📅 Date Extraction
GPTH uses multiple methods to determine correct photo dates:
1. **JSON metadata** (most accurate)
2. **EXIF data** from photo files
3. **Filename patterns** (Screenshot_20190919-053857.jpg, etc.)
4. **Aggressive matching** for difficult cases
5. **Folder year extraction** (Photos from 2005 → January 1, 2005)

### 🔍 Duplicate Detection
Removes identical files using content hashing, keeping the best copy (shortest filename, most metadata).

### 🌍 GPS Coordinates & Timestamps
Extracts location data and timestamps from JSON files and writes them to media file EXIF data for compatibility with photo viewers and other applications.

### 🎯 Smart File Handling
- **Motion Photos**: Pixel .MP/.MV files can be converted to .mp4
- **HEIC/RAW support**: Handles modern camera formats
- **Unicode filenames**: Properly handles international characters
- **Large files**: Optional size limits for resource-constrained systems

### 🤝 Partner Sharing Support
Separates partner shared media from personal uploads for better organization:
- **Automatic Detection**: Identifies partner shared photos from JSON metadata
- **Separate Folders**: Moves partner shared media to `PARTNER_SHARED` folder
- **Date Organization**: Applies same date division structure to partner shared content
- **Album Compatibility**: Works with all album handling modes

**Enable partner sharing separation:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --divide-partner-shared
```

### 📁 Flexible Organization
- Multiple date-based folder structures
- Preserve or reorganize album structure
- Move files efficiently from input to organized output structure
- Group Special Folders (`Trash`, `Archive`, `Locked Folder`) into `Special Folder` directory
- Group Untitled Albums into `Untitled Albums` directory

### 🔄 Auto-Resume Capability
- The tool detects if a previous execution was interrupted, and if so, when running again over the same output folder, it tries to resume from the step where it was interrupted.
- For this function to work, the input and ouput folders should be the same as the previous execution.
- In interactive mode, GPTH asks whether to resume the previous run or start fresh whenever saved progress is found in the output folder. In CLI mode, pass `--no-resume` to discard the saved progress and always start fresh.
- If the saved progress claims processing was completed but the recorded output files no longer exist (e.g. you emptied the output folder between runs), the stale state is discarded automatically and the run starts fresh.

> [!IMPORTANT]  
> - This feature only works if you maintain your input and output folder from the previous execution and if the files in your input folder are not in Zip format.
> - If you used the flag `--keep-input` in your first execution, then for the resume to take effect you need to use as input folder the folder where your input was cloned (typically with the same name as your input folder and a suffix like `_tmp`).

## Changelog
- Find the whole changelog file [here](CHANGELOG.md)

## Troubleshooting

### Common Issues

**"No photos found"**: Make sure you have a unified Takeout folder structure with "Photos from YYYY" folders.

**Permission errors**: Run with administrator/sudo privileges if moving files across drives.

**Memory issues**: Use `--limit-filesize` for systems with limited RAM.

**Encoding errors**: Some JSON files may have encoding issues; the tool handles most cases automatically.

### Platform-Specific Notes

**Windows**: Creation time updates require administrator privileges.

**macOS**: You may need to allow the executable in Security & Privacy settings.

## Support the Project

If you'd like to support development, you can buy me a coffee at:

- [https://revolut.me/jens](https://revolut.me/jens)

Also, I am actually a cyber security freelancer from Germany and I am looking for co-authors of the open [Cyber Risk Modelling Language](https://github.com/Faux16/crml). A language to represent cyber risks (and a small reference risk engine).
Feel free to follow me on [linkedin](https://www.linkedin.com/in/jens-attenberger) if you are interested in colaborating on CRML or if you represent a business and would like me to check your information security posture or you need honest and independent consulting.

## Related Projects

- **[PhotoMigrator](https://github.com/jaimetur/PhotoMigrator)**: Complete Migration tool that uses GPTH 6.x.x, and has been designed to interact and manage different photos cloud services. Allows users to do an automatic migration from one photo ploud service to another or from one account to a new account of the same photo cloud service.
- **[Google Keep Exporter](https://github.com/vHanda/google-keep-exporter)**: Export Google Keep notes to Markdown

## After Migration

### Recommended Apps
- **[Immich](https://immich.app/)**: Self-hosted Google Photos alternative
- **[PhotoPrism](https://photoprism.org/)**: AI-powered photo management
- **[Syncthing](https://syncthing.net/)**: Sync photos across devices while preserving dates

## 📈 Star History
<a href="https://www.star-history.com/#Xentraxx/GooglePhotosTakeoutHelper&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Xentraxx/GooglePhotosTakeoutHelper&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Xentraxx/GooglePhotosTakeoutHelper&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Xentraxx/GooglePhotosTakeoutHelper&type=Date" />
 </picture>
</a>

## 👥 Contributors
<a href="https://github.com/Xentraxx/GooglePhotosTakeoutHelper/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=Xentraxx/GooglePhotosTakeoutHelper" width="100%"/>
</a>
