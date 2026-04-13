# Google Photos Takeout Helper Neo 📸

[![Downloads](https://img.shields.io/github/downloads/Xentraxx/GooglePhotosTakeoutHelper_Neo/total?label=downloads)](https://github.com/Xentraxx/GooglePhotosTakeoutHelper_Neo/releases/)
[![Issues](https://img.shields.io/github/issues-closed/Xentraxx/GooglePhotosTakeoutHelper_Neo?label=resolved%20issues)](https://github.com/Xentraxx/GooglePhotosTakeoutHelper_Neo/issues)

Transform your chaotic Google Photos Takeout into organized photo libraries with proper dates, albums, and metadata.

**Acknowledgment**: This project is based on the original work by [TheLastGimbus](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper). We are grateful for their foundational contributions to the Google Photos Takeout ecosystem.
Also thank you to @jaimetur for your significant contributions to this fork!

## What This Tool Does

When you export photos from Google Photos using [Google Takeout](https://takeout.google.com/), you get a mess of folders with weird `.json` files and broken timestamps. This tool:

- ✅ **Organizes photos chronologically** with correct dates
- ✅ **Restores album structure** with multiple handling options
- ✅ **Fixes timestamps** from JSON metadata and EXIF data
- ✅ **Writes GPS coordinates and timestamps** back to media files (requires ExifTool for non-JPEG formats)
- ✅ **Removes duplicates** automatically
- ✅ **Handles special formats** (HEIC, Motion Photos, etc.)
- ✅ **Fixes mismatches of file name and mime type** if google photos renamed e.g. a .heic to .jpeg (but mime type remains heic), due to storage saver mode, we can fix this mismatch

Please note the [wiki](https://github.com/Xentraxx/GooglePhotosTakeoutHelper/wiki) is not yet complete but contains more technical details if you are looking for more information about how everything works.

## Installation & Setup

### 1. Download GPTH

Download the latest executable from [releases](https://github.com/Xentraxx/GooglePhotosTakeoutHelper/releases)

**Package Managers:**
- **Arch Linux**: `yay -S gpth-bin` (Maintained by TheLastGimbus, so this does not work with my fork. Just kept it here in case he merges my fork into the original project)

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
2. Deselect all, then select only **Google Photos**
3. Download all ZIP files

<!--suppress ALL -->
<img width="75%" alt="gpth usage image tutorial" src="https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/assets/40139196/8e85f58c-9958-466a-a176-51af85bb73dd">

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

**Interactive Mode** (recommended for beginners):
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

**Advantages:**
- Saves maximum disk space (no duplicate files)
- Maintains album organization
- Fast processing
- Better compatibility with cloud services and file type detection
- Works across all platforms (Windows, Mac, Linux)

**Disadvantages:**
- Requires symbolic link support (most modern systems support this)
- Some older applications may not follow symlinks properly

**Best for:** Most users who want space efficiency and better compatibility with modern applications and cloud services.

### 2. 🔄 Reverse Shortcut
**What it does:** The opposite of shortcut mode. Files remain in their original album folders, and shortcuts are created in `ALL_PHOTOS` pointing to the album locations.

**Advantages:**
- Preserves album-centric organization
- Original files stay in their natural album context
- Good for users who primarily browse by albums

**Disadvantages:**
- `ALL_PHOTOS` becomes dependent on album folders
- If a photo is in multiple albums, only one copy exists (in first album found)
- Shortcuts in `ALL_PHOTOS` may break if album folders are moved

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

Use `--transform-pixel-mp mp4` to rename Pixel `.MP` / `.MV` motion-photo files to `.mp4`.

Use `--transform-pixel-mp jpg` to create motion `.jpg` files from Pixel `.MP` / `.MV` motion photos.

Use `--transform-pixel-mp still` to keep only a still image and remove the related `.MP` / `.MV` source file.

For `still`, GPTH prefers an existing sidecar still image (for example `*.MP.jpg`) and falls back to extracting the embedded JPEG if no sidecar image exists.

For `jpg`, GPTH also prefers a sidecar still image (for example `*.MP.jpg`) when available, and falls back to embedded JPEG extraction from the motion file when no sidecar is found.

> [!WARNING]
> `--transform-pixel-mp jpg` is currently in **preview**. The conversion path is experimental and may be unstable depending on the source motion-photo structure.

### Extension Fixing Modes

Google Photos has an option of 'data saving' which will compress images to JPEG format but retain the original filename extension. Additionally, some web-downloaded images may have incorrect extensions (e.g., a file named `.jpeg` may actually be `.heif` internally).

GPTH natively writes EXIF data to files with JPEG signatures, while other formats require ExifTool. Files with mismatched extensions can cause ExifTool to fail, so GPTH provides several extension fixing strategies.

You can configure extension fixing behavior with:

| Argument                        | Description                                           | Technical Details                                                                                                                                                   | When to Use                                                                                                   |
|---------------------------------|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| `--fix-extensions=none`         | **Disable extension fixing entirely**                 | Files keep their original extensions regardless of content type. EXIF writing may fail for mismatched files.                                                        | When you're certain all extensions are correct, or when you want to preserve original filenames at all costs. |
| `--fix-extensions=standard`     | **Default: Fix extensions but skip TIFF-based files** | Renames files where extension doesn't match MIME type, but avoids TIFF-based formats (like RAW files from cameras) which are often misidentified by MIME detection. | **Recommended for most users**. Balances safety with effectiveness. Good for typical Google Photos exports.   |
| `--fix-extensions=conservative` | **Skip both TIFF-based and JPEG files**               | Most cautious approach - only fixes clearly incorrect extensions while avoiding both TIFF formats AND actual JPEG files to prevent any potential issues.            | When you have valuable photos and want maximum safety, or when you've had issues with previous modes.         |
| `--fix-extensions=solo`         | **Fix extensions then exit immediately**              | Performs extension fixing as a standalone operation without running the full GPTH processing pipeline. Useful for preprocessing files before the main operation.    | When you want to fix extensions first, then run GPTH again, or when integrating with other tools.             |

#### Why These Modes Exist

**The TIFF Problem**: Many RAW camera formats (CR2, NEF, ARW, etc.) are based on the TIFF specification internally. Standard MIME type detection often identifies these as `image/tiff`, which could cause the tool to rename `photo.CR2` to `photo.CR2.tiff`, potentially breaking camera software compatibility.

**The JPEG Complexity**: While JPEG files are generally safe to rename, the `conservative` mode provides an extra safety net for users who prefer minimal changes to their photo collections.

**ExifTool Dependencies**: When extensions don't match content, ExifTool operations fail. The extension fixing resolves this by ensuring filenames accurately reflect file content, enabling proper metadata writing.

**NOTE**: Some RAW formats are TIFF-based internally and contain TIFF headers - the extension fixing modes are designed to avoid incorrectly renaming these files.

#### Practical Examples

**Scenario 1: Google Photos Data Saver**
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
gpth --input "~/Takeout" --output "~/Photos" --transform-pixel-mp --albums "duplicate-copy"
```

**Separate partner shared media with date organization:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --divide-partner-shared --divide-to-dates 1
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

> [!IMPORTANT]  
> - This feature only works if you maitain your input and output folder from previous execution and if the files in your input folder are not in Zip format.
> - If you used the flag `--keep-input` in your first execution, then for the resume to take effect you need to use as input folder the folder where your input was cloned (tipically with the same name as your input folder and a suffix like `_tmp`).

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

**Linux**: Ensure ExifTool is installed for full functionality.

## After Migration

### Recommended Apps
- **[Immich](https://immich.app/)**: Self-hosted Google Photos alternative
- **[PhotoPrism](https://photoprism.org/)**: AI-powered photo management
- **[Syncthing](https://syncthing.net/)**: Sync photos across devices while preserving dates

### Android Users
Standard file managers reset photo dates when moving files. Use **Simple Gallery** to preserve timestamps.

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

## Related Projects

- **[PhotoMigrator](https://github.com/jaimetur/PhotoMigrator)**: Complete Migratin tool that uses GPTH 4.x.x, and has been designed to Interact and Manage different Photos Cloud services. Allow users to do an Automatic Migration from one Photo Cloud service to other or from one account to a new account of the same Photo Cloud service.
- **[Google Keep Exporter](https://github.com/vHanda/google-keep-exporter)**: Export Google Keep notes to Markdown

---

**Note**: This tool moves files by default to avoid using extra disk space. Always keep backups of your original Takeout files!
