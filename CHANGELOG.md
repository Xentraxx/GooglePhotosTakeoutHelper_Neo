## 5.1.0
### 🐛 **Bug Fixes**
  - Upgraded mime package to 2.0.0 (contains bugfix)
  - Added german and spanish "Photos from" localization.
  - Fixed an issue with MacOS unicode normalisation (#99)

## 5.0.9
### 🐛 **Bug Fixes**
  - Fixed a UTC conversion bug
  - Fixed that geodata was removed from exif
  - fixed a bug where a path join used a unix path seperator instead of being platform agnostic.

## 5.0.8
### 🐛 **Bug Fixes**
  - Updated upstream library to image 4.7.2 which contains fixes to the native writeExif() method.

## 5.0.7

### 🐛 **Bug Fixes**
  - ZIP extraction no longer deletes an existing extraction directory. GPTH now refuses to extract into a non-empty folder to prevent accidental deletion of unrelated files.
  - Interactive mode: Added an explicit **DANGER** warning before confirming output directory cleanup (deletes recursively inside the chosen output folder).

### ✨ **New Features**
  - Restore truncated media filenames from JSON sidecars (uses the JSON `title` field) after date extraction, renaming both the media file and its JSON metadata so later steps use the original name.

## 5.0.6

### 🐛 **Bug Fixes**
  - Fixed german unknown folder name from "unbekannt" to "Unbenannt" to correctly identify unknown folders (please create a bug report if those folders are exported in your language and provide us with the correct translation)
  - fixed unit tests
  - fixed partner sharing logic

## 5.0.6

### ✨ **New Features**
  - Added Auto-Resume support to avoid repeat successful steps when tool is interrupted and executed again on the same output folder. (#87).

### 🚀 **Improvements**
  - Untitled Albums now are detected and moved to `Untitled Albums` forder. (only if albums strategy is `shortcut`, `reversed-shortcut` or `duplicate-copy`, the rest of albums strategies don't creates albums folders). (#86).
  - Upgraded exif_reader package to the newest version.

### 🐛 **Bug Fixes**
  - Minor Bug Fixing.
  - Fixed #90 (duplicated output in interactive mode)
  - Fixed major error which led to native exif write methods not being used when exiftool was not installed.
  - Fixed issue with App1 marker in image library when jpg has no exif block. Using own fork of image library until pull request to the source repo is accepted. Fixes issue #95

## 5.0.5

### ✨ **New Features**
  - Added support for Special Folders management such as `Archive`, `Trash`, `Locked folder`. Now those folders are excluded from all album strategies and are moved directly to the output folder.

### 🚀 **Improvements**
  - Moved logic of each Step to step's service module. Now each step has a service associated to it which includes all the logic and interation with other services used by this step.
  - Added percentages to all progress bars.
  - Added Total time to Telemetry Summary in Step 3.
  - Fixed _extractBadPathsFromExifError method to detect from exiftool output bad files with relative paths.
  - Performance Improvements in `step_03_merge_media_entities_service.dart`.
    - Now grouping method can be easily changed. Internal `_fullHashGroup` is now used instead of 'groupIdenticalFast' to avoid calculate buckets again.

### 🐛 **Bug Fixes**
  - Fixed duplicated files/symlinks in Albums when a file belong to more than 1 album (affected strategies: shortcut, reverse-shortcut & duplicate-copy).
  - Fixed error decoding Exiftool output with UTF-8/latin chars.
  - Fix exiftool reader fails on path with mojibake.


## 5.0.4

### ✨ **New Features**
  - New album moving strategy `ignore` to completely ignore all Albums content. The difference with `nothing` strategy is that `nothing` don't create Albums folders but process and move all Albums content into `ALL_PHOTOS` folder.

### 🚀 **Improvements**
  - Moving Strategies re-defined.
  - Included Timeouts on ExifTool operations.
  - Log saving enabled by default. Use flag `--no-save-log` to disable it.
  - Changed log name from `gpth-{version}_{timestamp}.log` to `gpth_{version}_{timestamp}.log`
  - Added progress bar to Step 3 (Merge Media Entities).
  - Changed default value for flag `--update-creation-time. Now is enabled by default.
  - Smart split in writeBatchSafe: we parse stderr, separate only the conflicting files, retry the rest in a single batch, and write the conflicting ones per-file (without blocking progress). If paths can’t be extracted, we fall back to your original recursive split.
  - Added Progress bar on Step 1 & Step 2.

### 🐛 **Bug Fixes**
  - Added `reverse-shortcut` strategy to interactive mode.
  - Fixed some moving strategies that was missing some files in the input folder.
  - Fixed exiftool_service.dart to avoid IFD0 pointer references.
  - Fixed exiftool_service.dart to avoid use of -common_args when -@ ARGFILE is used.
  - Fixed PNG management writting XMP instead of EXIF for those files.
  - (ExifToolService): I added -F to the common arguments (_commonWriteArgs). It’s an immediate patch that often turns “Truncated InteropIFD” into a success.
  - (Step 7): If we detect a “problematic” JPEG, we force XMP (CreateDate/DateTimeOriginal/ModifyDate + signed GPS), both when initially building the tags (via _forceJpegXmp) and again on retry when a batch fails and stderr contains Truncated InteropIFD (in-place conversion of those entries with _retagEntryToXmpIfJpeg).


## 5.0.3

### 🚀 **Improvements**
  - Replace all `print()` functions by `logPrint()` method from LoggerMixin class. In this way all messages are registered both on screen and also on the logger (and saved to disk if flag `--save-log` is enabled).
  - All console messages have now a Step prefix to identify from which step or service they come from.


## 5.0.2

### ✨ **New Features**
  - New flag `--save-log` to enable/disable messages log saving into output folder.
  - Step 8 (Update creation time) is now multi-platform. Also update creation date for physical files and symlinks on linux/macos.

### 🚀 **Improvements**
  - New code re-design to include a new `MediaEntity` model with the following attributes:
    - `albumsMap`: List of AlbumsInfo obects,  where each object represent the album where each file of the media entity have been found. This List which can contain many usefull info related to the Album.
    - `dateTaken`: a single dataTaken for all the files within the entity
    - `dateAccuracy`: a single dateAccuracy for all the files within the entity (based on which extraction method have been used to extract the date)
    - `dateTimeExtractionMethod`: a single dateTimeExtractionMethod for all the files within the entity (method used to extract the dataTaken assigned to the entity)
    - `partnerShared`: true if the entity is partnerShared
    - `primaryFile`: contains the best ranked file within all the entity files (canonical first, then secondaries ranked by lenght of basename, then lenght of pathname)
    - `secondaryFiles`: contains all the secondary files in the entity
    - `duplicatesFiles`: contains files which has at least one more file within the entity in the same folder (duplicates within folder)
  - Created internal/external methods for Class `MediaEntity` for an easy utilization.
  - All modules have been adapted to the new `MediaEntity` structure.
  - All Tests have been adapted to the new `MediaEntity` structure.
  - Removed `files` attribute from `MediaEntity` Class.
  - Merged `media_entity_moving_strategy.dart` module with `media_entity_moving_service.dart` module and now it is stored under `lib/steps/step_06_moving_files/services` folder.
  - New behaviour during `Find Duplicates` step:
    - Now, all identical content files are collected within the same MediaEntity.
      - In a typical Takeout, you might have the same file within `Photos from yyyy` folder and within one or more Album folder
      - So, both of them are collected within the same entity and will not be considered as duplicated because one of them could have associated json and the others not
      - So, we should extract dates for all the files within the same media entity.
    - If one media entity contains two or more files within the same folder, then this is a duplicated file (based on content), even if they have different names, and the tool will remove the worst ranked duplicated file.
  - Moved `Write EXIF` step to Step 7 (after Move Files step) in order to write EXIF data only to those physical files in output folder (skipping shortcuts). 
    - This changed was needed because until Step 6 (based on the selected album strategy), don't create the output physical files, we don't know which files need EXIF write. 
    - With this change we reduce a lot the number of EXIF files to write because we can skip writing EXIF for shortcut files created by shorcut or reverse-shortcut strategy, but also we can skip all secondaryFiles if selected strategy is None or Json. 
    - The only strategy that has no benefit from this change is duplicate-copy, because in this strategy all files in output folder are physical files and all of them need to have EXIF written.
  - Renamed `Step 3: Remove Duplicates` to `Step 3: Merge Media Entities` because this represents much better the main purpose of this step. 
  - **Performance Optimization in `Step 3: Merge Media Entities`.**
  - `Step 3: Merge Media Entities` now only consider within-folder duplicates. And take care of the primaryFile/secondaryFiles based on a ranking for the rest of the pipeline.
  - `Step 7: Write EXIF` now take into account all the files in the MediaEntity file except duplicatesFiles and files with `isShortcut=true` attribute. 
  - `Step 6: Move Files` now manage hardlinks/juntions as fallback of native shorcuts using API to `WindowsSymlinkService` when no admin rights are granted.
  - `Step 8: Update Creation Time`now take into account all the files in the MediaEntity file except duplicatesFiles.
  - `Step 8: Update Creation Time`now update creation time also for shortcuts.
  - Improvements on Statistics results.
    - Added more statistics to `Step 3: Remove Duplicate` 
    - Added more statistics to `Step 6: Move Files` 
    - Added more statistics to `Step 8: Update Creation Time`.
    - Total execution time is now shown as hh:mm:ss instead of only minutes.
  - Added new flag `enableTelemetryInMergeMediaEntitiesStep`in `GlobalConfigService` Class to enable/disable Telemetry in Step 3: Merge Media Entities.


### 🐛 **Bug Fixes**
  - Fixed #65: Now all supported media files are moved from input folder to output folder. So after running GPTH input folder should only contain .json files and unsupported media types.
  - Fixed #76: Now interactive mode ask for album strategy.
  - Changed zip_extraction_service.dart to support extract UTF-8/latin1 chars on folder/files names.


## 5.0.1

### 🚀 **Improvements**
  - Performance Optimization in Step 3 (Remove Duplicates)


## 5.0.0

### ✨ **New Features**
  - Support for 7zip and unzip extractors (if found in your system). This is because the native extractor does not extract properly filenames or dirnames with UTF-8/latin1 chars.
  - Support new `Extra` files from Google Takeout with following suffixes: `-motion`, `-animation`, `-collage`.
  - New flag `--keep-input` to Work on a temporary sibling copy of --input (suffix _tmp), keeping the original untouched.
  - New flag `--keep-duplicates` to keep duplicates files in `_Duplicates` subfolder within output folder.
  - Created GitHub Action `build-and-create-release.yml` to Automatically build all binaries, create new release (stable or pre-release), update it wiht the release-notes and upload the binaries to the new release.

### 🚀 **Improvements**
  - Created a single package gpth-lib with all the exported modules for an easier way to manage imports and refactoring.
  - Added new flag `fallbackToExifToolOnNativeMiss`in `GlobalConfigService` Class to specify if we want to fallback to ExifTool on Native EXIF reader fail. (Normally if Native fails is because EXIF is corrupt, so fallback to ExifTool does not help).
  - Added new flag `enableExifToolBatch`in `GlobalConfigService` Class to specify if we want to enable/disable call ExifTool with batches of files instead of one call per file (this speed-up a lot the EXIF writting time with ExifTool).
  - Added new flag `maxExifImageBatchSize`in `GlobalConfigService` Class to specify the maximum number of Images for each batch passed in any call to ExifTool.
  - Added new flag `maxExifVideoBatchSize`in `GlobalConfigService` Class to specify the maximum number of Videos for each batch passed in any call to ExifTool.
  - Added new flag `forceProcessUnsupportedFormats`in `GlobalConfigService` Class to specify if we want to forze process unsupported format such as `.AVI`, `.MPG`or `.BMP` files with ExifTool.
  - Added new flag `silenceUnsupportedWarnings`in `GlobalConfigService` Class to specify if we want to recive or silence warnings due to unsupported format on ExifTool calls.
  - `MediaEntity` Class changed
    - Removed `files` attribute
    - Added `primaryFile` and `secondaryFiles` attributes for a better logic.
    - Added `albumsMap` attribute to store All Albums where the media entity was found as a `AlbumInfo` List which can contain many usefull info related to the Album.
    - Adapted all methods to work with this new structure
  - All modules have been adapted to the new `MediaEntity` structure.
  - All Tests have been adapted to the new `MediaEntity` structure.
  - Code Structure refactored for a better understanding and easier way to find each module.
  - Code Refactored to isolate the execution logic of each step into the .execute() function of the step's class. In this way the media_entity_collection module is much clearer and easy to understand and maintain.
  - Homogenized logs for all steps.
  - Improvements on Statistics results.

### 🐛 **Bug Fixes**
  - Fixed #65: Now all supported media files are moved from input folder to output folder. So after running GPTH input folder should only contain .json files and unsupported media types.
  - Fixed #76: Now interactive mode ask for album strategy.

## 4.3.1

### 🚀 **Improvements**
  - Improve Performance in Remove Duplicates Step
  - Change README.md to add Star History & Contributors History

### 🐛 **Bug Fixes**
  - Added ask for Albums strategy during interactive mode


## 4.3.0

### ✨ **New Features**
  - New flag `--json-dates` to provide a JSON dictionary with the date per file to void reading it from EXIF when any file does not associated sidecar. (PhotoMigrator creates this file and can now be used by GPTH Tool).
  - Improved log/print messages in all Steps.
  - Added Move Files Summary to the log messages.
  - Now Album's folders are moved into `Albums` folder and No-Album's files are moved into `ALL_PHOTOS` folder using the selected date organization.

### 🚀 **Improvements**

  - #### Step 4 (Extract Dates) & 5 (Write EXIF) Optimization
    - ##### ⚡ Performance
      - Step 4 (READ-EXIF) now uses batch reads and a fast native mode, with ExifTool only as fallback → about 3x faster metadata extraction.  
      - Step 5 (WRITE-EXIF) supports batch writes and argfile mode, plus native JPEG writers → up to 5x faster on large collections.
        - The function `writeExifData()` now accepts a parameter called `exifToolBatching` to Enable/Disable Batch processing with Exiftool.
    - ##### 🔧 API
      - Added batch write methods in `ExifToolService`.  
      - Updated `MediaEntityCollection` to use new helpers for counting written tags.
    - ##### 📊 Logging
      - Statistics are clearer: calls, hits, misses, fallback attempts, timings.  
      - Date, GPS, and combined writes are reported separately.  
      - Removed extra blank lines for cleaner output.
    - ##### 🧪 Testing
      - Extended mocks with batch support and error simulation.  
      - Added tests for GPS writing, batch operations, and non-image handling.
    - ##### ✅ Benefits
      - Much faster EXIF processing with less ExifTool overhead.  
      - More reliable and structured API.  
      - Logging is easier to read and interpret.  
      - Stronger test coverage across edge cases.  

  - #### Step 6 (Find Albums) Optimization
    - ##### ⚡ Performance
      - Replaced `_groupIdenticalMedia` with `_groupIdenticalMediaOptimized`.  
        - Two-phase strategy:  
          - First group by file **size** (cheap).  
          - Only hash files that share the same size.  
        - Switched from `readAsBytes()` (full memory load) to **streaming hashing** with `md5.bind(file.openRead())`.  
        - Files are processed in **parallel batches** instead of sequentially.  
        - Concurrency defaults to number of CPU cores, configurable via `maxConcurrent`.
    - ##### 🔧 Implementation
      - Added an in-memory **hash cache** keyed by `(path|size|mtime)` to avoid recalculating.  
        - Introduced a custom **semaphore** to limit concurrent hashing and prevent I/O overload.  
        - Errors are handled gracefully: unprocessable files go into dedicated groups without breaking the process.
    - ##### ✅ Benefits
      - Processing time reduced from **1m20s → 4s** on large collections.  
        - Greatly reduced memory usage.  
        - Scales better on multi-core systems.  
        - More robust and fault-tolerant album detection.  

### 🐛 **Bug Fixes**
  - Handle per file exception in WriteExif Step. Now the flow continues if any file fails to write EXIF.
  - Fixed interactive mode when asking to limit the file size.
  - Show dictMiss files in log to see those files that have not been found in dates dictionary when it was passed as argument using --json-dates
  - Fix missing JSON match when the length of the original JSON filename is higher than 51. Now try first with the full filename even if its length is longer than 51 chars, if not match, then try the different truncations variants.
  - Fix Progress bar on Step 7: Move files. Now counts the number of real operations instead of number of move instances.
  - Fixed some other silent exceptions.


## 4.1.1-Xentraxx

### 🐛 **Bug Fixes**
  - **changed exif tags to be utilized** - Before we used the following lists of tags in this exact order to find a date to set: 
    - Exiftool reading: 'DateTimeOriginal', 'MediaCreateDate', 'CreationDate', 'TrackCreateDate', 'CreateDate', 'DateTimeDigitized', 'GPSDateStamp' and 'DateTime'.
    - Native dart exif reading: 'Image DateTime', 'EXIF DateTimeOriginal', 'EXIF DateTimeDigitized'.
  Some of those values are prone to deliver wrong dates (e.g. DateTimeDigitized) and the order did not completely make sense.
  We therefore now read those tags and the the oldest DateTime we can find:
    - Exiftool reading: 'DateTimeOriginal','DateTime','CreateDate','DateCreated','CreationDate','MediaCreateDate','TrackCreateDate','EncodedDate','MetadataDate','ModifyDate'.
    - Native dart exif reading: same as above.
  - **Fixed typo in partner sharing** - Functionality was fundamentally broken due to a typo.
  - **Fixed small bug in interactive mode in the options of the limit filezise dialogue**
  - **Fixed unzipping through command line by automatically detecting if input directory contains zip files**

### 🚀 **Improvements**
  - **Improved non-zero exit code quitting behaviour** - Now with nice descriptive error messages because I was tired of looking up what is responsible for a certain exit code.
  - **Standardized concurrency & logging** - All parallel operations now obtain limits exclusively through `ConcurrencyManager` / `GlobalPools` (hashing, EXIF extraction/writing, duplicate detection, grouping, moving, file I/O). Added consistent one-time or operation-start log lines like `Starting N threads (<operation> concurrency)`; removed deprecated `maxConcurrency` parameters and legacy random placeholder logic from `ProcessingLimits`. Lightweight operations (e.g. disk space checks) intentionally left sequential to avoid overhead.

## 4.1.0-Xentraxx - Bug Fixes and Performance Improvements

### ✨ **New Features**
- **Partner Sharing Support** - Added `--divide-partner-shared` flag to separate partner shared media from personal uploads into dedicated `PARTNER_SHARED` folder (Issue #56)
  - Automatically detects partner shared photos from JSON metadata (`googlePhotosOrigin.fromPartnerSharing`)
  - Creates separate folder structure while maintaining date division and album organization
  - Works with all album handling modes (shortcut, duplicate-copy, reverse-shortcut, json, nothing)
  - Preserves album relationships for partner shared media
- **Added folder year date extraction strategy** - New fallback date extractor that extracts year from parent folder names like "Photos from 2005" when other extraction methods fail (Issue #28)
- **Centralized concurrency management** - Introduced `ConcurrencyManager` for consistent concurrency calculations across all services, eliminating hardcoded multipliers scattered throughout the codebase
- **Displaying version of Exiftool when found** - Instead of just displaying that Exif tool was found, we display the version now as well.

### 🚀 **Performance Improvements**
- **EXIF processing optimization** - Native `exif_reader` library integration for 15-40% performance improvement in EXIF data extraction
  - Uses fast native library for supported formats (JPEG, TIFF, HEIC, PNG, WebP, AVIF, JXL, CR3, RAF, ARW, DNG, CRW, NEF, NRW)
  - Automatic fallback to ExifTool for unsupported formats or when native extraction fails
  - Centralized MIME type constants verified against actual library source code
  - Improved error logging with GitHub issue reporting guidance when native extraction fails
- **GPS coordinate extraction optimization** - Dedicated coordinate extraction service with native library support
  - 15-40% performance improvement for GPS-heavy photo collections
  - Clean architectural separation between date and coordinate extraction
  - Centralized MIME type support across all EXIF processing operations
- **Significantly increased parallelization** - Changed CPU concurrency multiplier from ×2 to ×8 for most operations, dramatically improving performance on multi-core systems
- **Removed concurrency caps** - Eliminated `.clamp()` limits that were artificially restricting parallelization on high-core systems
- **Platform-optimized concurrency**:
  - **Linux**: Improved from `CPU cores + 1` to `CPU cores × 8` (massive improvement for Linux users)
  - **macOS**: Improved from `CPU cores + 1` to `CPU cores × 6` 
  - **Windows**: Maintained at `CPU cores × 8` (already optimized)
- **Operation-specific concurrency tuning**:
  - **Hash operations**: `CPU cores × 4` (balanced for CPU + I/O workload)
  - **EXIF/Metadata**: `CPU cores × 6` (I/O optimized for modern SSDs)
  - **Duplicate detection**: `CPU cores × 6` (memory intensive, conservative)
  - **Network operations**: `CPU cores × 16` (high for I/O waiting)
- **Adaptive concurrency scaling** - Dynamic performance-based concurrency adjustment that scales up to ×24 for high-performance scenarios

### 🐛 **Bug Fixes**
- **Fixed memory exhaustion during ZIP extraction** - Implemented streaming extraction to handle large ZIP files without running out of memory
- **Fixed atomic file operations** - Changed to atomic file rename operations to resolve situations where only the json was renamed in file extension correction (Issue #60)
- **Fixed album relationship processing** - Improved album relationship service to handle edge cases properly (Issue #61)
- **Fixed interactive presenter display** - Corrected display issue in interactive mode (Issue #62)
- **Fixed date division behavior for albums** - The `--divide-to-dates` flag now only applies to ALL_PHOTOS folder, leaving album folders flattened without date subfolders (Issue #55)
- **Reaorganised ReadMe for a more intuitive structure** - First Installation, then prerequisites and then the quickstart.
- **Step 8 now also uses a progress bar instead of simple print statements**
- **Supressed some unnecessary ouput**

## 4.0.9-Xentraxx - Major Architecture Refactor

### 🛡️ **BREAKING CHANGE: Copy Mode Completely Removed**

This release removes the `--copy` flag and all copy mode functionality to ensure **complete input directory safety** and eliminate data integrity issues.

#### **Why This Change Was Made**
- **Input Directory Protection**: Copy mode was modifying files in the input directory during extension fixing and filename sanitization, violating the principle of data safety
- **Simplified Architecture**: Removes complex conditional logic that led to inconsistent behavior
- **Clearer User Intent**: All operations now clearly move files from input to output, with no ambiguity
- **Enhanced Reliability**: Eliminates edge cases where input files could be modified unexpectedly

#### **Breaking Changes**
- **❌ Removed**: `--copy` command line flag
- **❌ Removed**: `copyMode` from all configuration APIs
- **❌ Removed**: Copy-related conditional logic throughout codebase
- **✅ New Behavior**: All files are **always moved** from input to output directory

#### **Migration Guide**
- **Before**: `gpth --input source --output dest --copy`
- **After**: `gpth --input source --output dest` (copy flag no longer needed or supported)
- **Result**: Files will be moved (not copied) from source to destination
- **Behavior**: Files are relocated from input to output directory with metadata processing applied

#### **Technical Implementation**
- **FileOperationService**: Simplified to move-only operations with cross-device copy+delete fallback
- **Moving Strategies**: All strategies now use consistent move semantics
- **Album Strategies**: Duplicate copy strategy still creates copies in album folders when needed
- **Configuration System**: Streamlined without copy mode complexity

#### **Benefits**
- **⚡ Better Performance**: Simplified logic reduces overhead
- **🧹 Cleaner Codebase**: Removed 400+ lines of conditional copy logic
- **🎯 Clearer Semantics**: Move operations are explicit and predictable

### 🛡️ **BREAKING CHANGE: fix extension flag renamed**

- **Consolidated extension fixing flags** into unified `--fix-extensions=<mode>` option
  - **Before**: `--fix-extensions`, `--fix-extensions-non-jpeg`, `--fix-extensions-solo-mode`
  - **After**: `--fix-extensions=<mode>` with `none`, `standard`, `conservative`, `solo` modes

### 🏗️ **Complete Architecture Overhaul**

This release represents a fundamental restructuring of the codebase following **Clean Architecture** principles, providing better maintainability, testability, and performance.

#### **Tl;dr**

- fix extenstion flag changed to `--fix-extensions=<mode>`
- Improved performance.
- **CRITICAL FIX**: Nothing mode now processes ALL files, preventing data loss in move mode

#### **Critical Bug Fixes**
- **🚨 FIXED: Data loss in Nothing mode** - Album-only files are now properly moved in Nothing mode instead of being silently skipped, preventing potential data loss when using move mode with `--album-behavior=nothing`

#### **Domain-Driven Design Implementation**
- **Reorganized codebase into distinct layers**: Domain, Infrastructure, and Presentation
- **Introduced service-oriented architecture** with dependency injection container
- **Implemented immutable domain entities** for better data integrity and performance
- **Added comprehensive test coverage** with over 200+ unit and integration tests

#### **Service Consolidation & Modernization**
- **Unified service interfaces** through consolidated service pattern
- **Implemented ServiceContainer** for centralized dependency management
- **Refactored moving logic** into strategy pattern with pluggable implementations
- **Enhanced error handling** with proper exception hierarchies and logging

### 🚀 **Performance & Reliability Improvements**

#### **Async Processing Architecture**
- **Stream-based file I/O operations** replacing synchronous access
- **Persistent ExifTool process** management (10-50x faster EXIF operations)
- **Concurrent media processing** with race condition protection
- **Memory optimization** - up to 99.4% reduction for large file operations

#### **Advanced File Operations**
- **Streaming hash calculations** (20% faster with reduced memory usage)
- **Optimized directory scanning** (50% fewer I/O operations)
- **Parallel file moving operations** (40-50% performance improvement)
- **Smart duplicate detection** with memory-efficient algorithms
- **Native Win32 creation time updates** - Replaced PowerShell with direct Win32 FFI calls (10-100x faster)

#### **Intelligent Extension Correction**
- **MIME type validation** with file header detection
- **RAW format protection** - prevents corruption of TIFF-based files
- **Comprehensive safety modes** for different use cases
- **JSON metadata synchronization** after extension fixes

### 📁 **Modern File Management**

#### **Strategy Pattern Implementation**
- **Pluggable moving strategies**: Nothing, Copy, Shortcut, Reverse Shortcut
- **Context-aware path generation** with date-based organization
- **Atomic file operations** with rollback capabilities
- **Smart collision handling** with unique filename generation

#### **Cross-Platform Improvements**
- **Platform-specific optimizations** for Windows, macOS, and Linux
- **Enhanced shortcut creation** bypassing PowerShell on Windows
- **Unified disk space management** across all platforms
- **Improved encoding handling** for international filenames

### 🧪 **Testing & Quality Assurance**

#### **Comprehensive Test Suite**
- **200+ automated tests** covering unit, integration, and end-to-end scenarios
- **Mock service infrastructure** for reliable testing
- **Performance regression testing** with benchmarks
- **Cross-platform validation** across all supported systems

#### **Code Quality Improvements**
- **Comprehensive documentation** with detailed function descriptions
- **Lint rule enforcement** following Dart best practices
- **Type safety enhancements** with null safety
- **Error logging standardization** with structured log levels

### 🔄 **Processing Pipeline Modernization**

#### **Eight-Step Pipeline Architecture**
1. **Extension Fixing** - Intelligent MIME type correction
2. **Media Discovery** - Optimized file system scanning
3. **Duplicate Removal** - Content-based deduplication
4. **Date Extraction** - Multi-source timestamp resolution
5. **EXIF Writing** - Metadata synchronization
6. **Album Detection** - Smart folder classification
7. **File Moving** - Strategy-based organization
8. **Creation Time Updates** - Final timestamp alignment

#### **Enhanced Data Processing**
- **MediaEntity immutable models** for thread-safe operations
- **Coordinate processing** with validation and conversion
- **JSON metadata matching** with truncated filename support
- **Album relationship management** with shortcut strategies

### 🛠️ **Infrastructure Enhancements**

#### **External Tool Integration**
- **Persistent ExifTool management** with automatic discovery
- **Platform service abstraction** for system-specific operations
- **Disk space monitoring** with real-time calculations
- **Process lifecycle management** with proper cleanup

#### **Interactive User Experience**
- **Consolidated interactive services** with improved prompts
- **Real-time progress reporting** for long-running operations
- **Enhanced error messages** with actionable guidance
- **ZIP extraction restoration** with security improvements

### 📋 **Configuration & Usability**

#### **Streamlined Configuration**
- **Unified command-line interface** with consistent flag patterns
- **Interactive configuration validation** with user guidance
- **Global configuration service** with centralized settings
- **Backward compatibility** for existing workflows

#### **Bug Fixes & Stability**
- **Race condition elimination** in concurrent operations
- **JSON file matching improvements** for truncated names
- **Memory leak prevention** in long-running processes
- **Cross-platform filename handling** improvements

## 4.0.8-Xentraxx

### Interactive ZIP File Extraction Restored

#### Major Feature Restoration
- **Restored interactive ZIP file extraction functionality** that was previously deprecated due to photo loss issues
- Added comprehensive security measures to prevent data loss and security vulnerabilities
- Implemented user-friendly choice between automatic ZIP extraction or using pre-extracted directories

#### New Interactive ZIP Features
- **`askIfUnzip()` function**: Provides users with clear options for handling Google Takeout data:
  - Option 1: Select ZIP files for automatic extraction (Recommended)
  - Option 2: Use already extracted directory
- **Enhanced `getZips()` function**: Improved file picker with better validation and user feedback
- **Secure `unzip()` function**: Comprehensive ZIP extraction with multiple safety layers

#### Security and Safety Improvements
- **ZIP Slip Protection**: Prevents malicious ZIP files from extracting outside the target directory
- **Cross-platform filename sanitization**: Handles encoding issues and invalid characters safely
- **Comprehensive error handling**: User-friendly error messages with actionable guidance
- **File integrity validation**: Verifies ZIP files before extraction
- **Progress reporting**: Real-time feedback during extraction process

#### Technical Enhancements
- **`_extractZipSafely()` helper**: Internal function with security checks and encoding handling
- **`_sanitizeFileName()` helper**: Cross-platform filename normalization and safety checks
- **`_handleExtractionError()` helper**: Context-specific error handling with detailed guidance
- **`SecurityException` class**: Custom exception for handling security-related extraction issues

#### Workflow Integration
- Seamlessly integrated into interactive mode with clear user prompts

### Extension Fixing Feature

- Added comprehensive file extension correction functionality to handle mismatched MIME types and extensions
- Added three CLI flags for different extension fixing behaviors:
  - `--fix-extensions`: Fixes incorrect extensions except for TIFF-based files (e.g., RAW formats)
  - `--fix-extensions-non-jpeg`: More conservative mode that also skips actual JPEG files  
  - `--fix-extensions-solo-mode`: Standalone mode that fixes extensions and exits without further processing
- Added interactive prompts for extension fixing configuration with three options for user convenience
- Enhanced EXIF writing error messages to suggest using `--fix-extensions` when extension/MIME type mismatches are detected
- Added comprehensive test coverage for extension fixing functionality including edge cases

### JSON File Matching Improvements

- Added support for removing partial extra format suffixes from truncated filenames (issue #29)
- Enhanced JSON file matching for media files with filename truncation due to filesystem limits
- Added `removePartialExtraFormats` function to handle cases where suffixes like "-ed" need to be removed to match corresponding JSON files
- Improved date extraction reliability for files with truncated names ending in partial extra format patterns

#### Technical Details

When filenames are truncated due to filesystem character limits, partial suffixes (e.g., "-ed" from "-edited") can prevent proper JSON file matching for date extraction. The new functionality identifies and removes these partial patterns, allowing the JSON extractor to find corresponding metadata files and extract accurate photo dates.

### Bug Fixes and Improvements

- Fixed EXIF writing to properly handle files with incorrect extensions by detecting MIME type mismatches
- Improved error logging with more informative messages about extension/MIME type conflicts
- Updated statistics reporting to include count of fixed file extensions
- Enhanced interactive mode with better user guidance for extension fixing options

### Technical Details

The extension fixing feature addresses a common issue where Google Photos' "data saving" option compresses images to JPEG format but retains original file extensions, or where web-downloaded images have incorrect extensions. The tool now:

1. Reads file headers to detect actual MIME type
2. Compares with extension-based MIME type detection
3. Skips TIFF-based files (like RAW formats) as they're often misidentified
4. Renames files with correct extensions and updates associated JSON metadata files
5. Provides detailed logging of the fixing process

The feature integrates seamlessly with the existing EXIF writing workflow, ensuring metadata can be properly written to files after extension correction.

## 4.0.7-Xentraxx

### Fork/Alternate version

#### Bug fixes

- Simplified year folder detection logic to strictly match "Photos from YYYY" format
- Updated folder classification tests to align with more restrictive year folder recognition
- Fixed test failures related to year folder pattern matching

#### General improvements

- Enhanced test coverage for folder classification functionality
- Improved test documentation and organization
- Strengthened year folder validation to prevent false positives
- Removed --modify-json flag from wachees fork due to issues.

## 4.0.5-wacheee-xentraxx-beta

### Fork/Alternate version

#### Bug fixes

- Fixed multiple serious race conditions
- Fixed serious problem where (1) was appended more than once
- Fixed serious bug where reverse-shortcut album mode was not creating albums
- Fixed serious bug where on windows .lnk was appended to a shortcut more than once
- Fixed bug where mimeType needs to be identified by file header for various RAW formats which are based on TIFF (Thank you @IreunN)

#### General improvements

- Added more than 200 unit and functional tests with documentation
- Documented every function comprehensively
- Improved general documentation in code
- Improved README to be more comprehensive
- Added CONTRIBUTING.md

## 4.0.4-wacheee-xentraxx-beta

### Fork/Alternate version

#### Bug fixes

- Changed Github actions from Ubuntu 24.04 to 22.04 for legacy Synology NAS support

## 4.0.3-wacheee-xentraxx-beta

### Fork/Alternate version

#### Bug fixes

- Relying on the emoji-regex package to find all emojis
- Added tests to find more emojis
- Fixed github build actions
- Fixed emoji logic to handle inivible characters (by @ireun (Thank you!))
- Made output nicer and fixed wrong mimeType lookup where exiftool would fail (by @ireun (Thank you!))
- Using ubuntu-22.04 instead of ubuntu-latest to build for legacy compatibility with old Synology NAS (thanks to @jaimetur)

## 4.0.2-wacheee-xentraxx-beta

### Fork/Alternate version

#### Bug fixes

- Removed some dysfunctional progress bars
- resolved typo in release notes

## 4.0.1-wacheee-xentraxx-beta

### Fork/Alternate version 
### This change is a big overhaul of the project, so only the major improvements or potential breaking changes are mentioned
### This version was developed mainly by @Xentraxx (https://github.com/Xentraxx/)

#### Tl;dr

- Added support for reading EXIF data from JXL (JPEG XL), ARW, RAW, DNG, CRW, CR3, NRW, NEF and RAF files internally.
- Adeded support for reading and writing coordinates and DateTime from and to exif for almost all file formats.
- Added a "--write-exif" flag which will write missing EXIF information (coordinates and DateTime) from json to EXIF for jpg and jpeg files
- Added support to get DateTime from .MOV, .MP4 and probably many other video formats through exiftool. You need to download it yourself (e.g. from here: https://exiftool.org/), rename it to exiftool.exe and make sure the folder you keep it in is in your $PATH variable or in the same folder as gpth.
- Added verbose mode (--verbose or -v)
- File size is not limited anymore by default but can be limited using the --limit-filesize flag for systems with low RAM (like a NAS).
- Fixed [PhotoMigrator](https://github.com/jaimetur/PhotoMigrator) integration by finding exiftool in more locations.
- Fixed some typos
- Fixed emoji to hex encoding and decoding and added support for BMP emojis in addition to surrowgate.
- Fixed some tests 


#### General improvements

- upgraded dependencies and fixed breaking changes
- updated dart to a minimum version of 3.8.0 of the dart SDK
- included image, intl and coordinate_converter packages
- applied a list of coding best practices through lint rules to code
- added/edited a bunch of comments and changed unnecessary print() to log() for debugging and a better user experience
- Divided code in steps through comments and included steps in output for readability, debuggability and to make it easier to follow the code
- checked TODOs in README.md
- Added TODOs to look into in code through //TODO comments
- moved json_extractor file into date_extractor folder
- added unit tests for new write-exif functionality
- made CLI --help output more readable through line breaks
- renamed some variables/functions to better reflect their purpose
- moved step 8 (update creation time) before final output
- added output how often DateTime and Coordinates have been written in EXIF at the final output
- changed that test data will be created in test subfolder instead of project root directory
- Added consistent log levels to log output to quickly differenciate between informational and error logs
- Added logging of elapsed time for each step.
- Exposed the maxFileSize flag as an argument (--limit-filesize) to set if necessary, It's now deactivated by default to support larger files like videos.
- Added DateTime extraction method statistics to the final output - shows how many files had their dates extracted through which method
- Added elapsed time logging for each processing step
- Improved Github actions

#### Bug fixes

- fixed existing unit tests which would fail on windows
- Fixed Github Actions

#### Added functionality

- Support for writing coordinates and DateTime to EXIF
  - Added new CLI option "--write-exif".
  - When enabled, the script will check if the associated json of any given file contains coordinates and if the file does not yet have them in its EXIF data, the script will add them.
  - When enabled, the script will check if a DateTime has been extracted from any of the given extraction methods and if the file has no EXIF DateTime set, it will add the DateTime to the EXIF data 'DateTime', 'DateTimeOriginal'and 'DateTimeDigitized'.
  - Added verbose mode (--verbose or -v) with log levels info, warning and error.

- Moved from the stale "exif" package to "exif_reader" for dart local exif reading, the image library for local jpeg exif writing and the external exiftool for all other EXIF reading and writing (images and videos)
  - The move to exif_reader adds support for extracting DateTime from JXL (JPEG XL), ARW, RAW, DNG, CRW, CR3, NRW, NEF and RAF files, and video formats like MOV, MP4, etc.
  - Exiftool needs to be in $PATH variable or in the same folder as the running binary. If not, that's okay. Then we fall back to exif_reader. But if you have ExifTool locally, Google Photos Takeout Helper now supports reading CreatedDateTime EXIF data for almost all media formats.

- Added new interactive prompts:
  - Option to write EXIF data to files (--write-exif)
  - Option to limit file size for systems with low RAM (--limit-filesize)

#### Limitations
- As mentioned on the PR https://github.com/Wacheee/GooglePhotosTakeoutHelper/pull/13#issuecomment-2910289503 this version can be slower than 3.6.x-wacheee in Windows because is using PowerShell to create shortcuts (FFI is causing heap exception)

##
<details>
<summary>Previous fixes and improvements</summary>
  
#####  *Previous fixes and improvement (from 3.4.3-wacheee to 4.0.0-wacheee)*
- *added macOS executables supporting both ARM64 and Intel architectures https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/310 https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/396#issuecomment-2787459117*
- *fixed an exception when using GPTH with command-line arguments https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/5 https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/8*
- *the "fix JSON metadata files" option can now be configured using command-line arguments https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/7 https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/9*
- *if `shortcut` option is selected, shortcut creation will be 10 times faster on Windows platforms (new creation method that avoids using PowerShell). For more details: [TheLastGimbus#390](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/390)*
- *fixed issues with folder names containing emojis  💖🤖🚀on Windows #389*
- *added an interactive option to update the creation times of files in the output folder to match their last modified times at the end of the program (only on Windows) #371*
- *if a media is not in a year folder it establishes one from an album to move it to ALL_PHOTOS correctly. This will move the original media file directly from the album (or one of those albums) to ALL_PHOTOS and create a shortcut in the output album folder (if shortcut option is selected) #261*
- *added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271*
- *added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4*
- *added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355*
- *fixed shortcut issue on Windows platforms #248*
- *added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))*
- *added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums*
  
##### *Limitations:*
- *if album mode is set to duplicate-copy, it will move the album photos to the album folder (as usual), but ALL_PHOTOS will not contain them if the media is not in a year album.*
- *it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.*
- *No interactive unzipping*

## 3.6.2-wacheee

### Fork/Alternate version 
#### macOS executables

- added macOS executables supporting both ARM64 and Intel architectures https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/310 https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/396#issuecomment-2787459117
  
##### *Previous fixes and improvement (from 3.4.3-wacheee to 3.6.1-wacheee)*
- *fixed an exception when using GPTH with command-line arguments https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/5 https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/8*
- *the "fix JSON metadata files" option can now be configured using command-line arguments https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/7 https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/9*
- *if `shortcut` option is selected, shortcut creation will be 10 times faster on Windows platforms (new creation method that avoids using PowerShell). For more details: [TheLastGimbus#390](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/390)*
- *fixed issues with folder names containing emojis  💖🤖🚀on Windows #389*
- *added an interactive option to update the creation times of files in the output folder to match their last modified times at the end of the program (only on Windows) #371*
- *if a media is not in a year folder it establishes one from an album to move it to ALL_PHOTOS correctly. This will move the original media file directly from the album (or one of those albums) to ALL_PHOTOS and create a shortcut in the output album folder (if shortcut option is selected) #261*
- *added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271*
- *added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4*
- *added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355*
- *fixed shortcut issue on Windows platforms #248*
- *added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))*
- *added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums*
  
##### *Limitations (previous fixes):*
- *if album mode is set to duplicate-copy, it will move the album photos to the album folder (as usual), but ALL_PHOTOS will not contain them if the media is not in a year album.*
- *it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.*

## 3.6.1-wacheee

### Fork/Alternate version 
#### Fixes for Command-Line Arguments

- fixed an exception when using GPTH with command-line arguments https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/5 https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/8
- the "fix JSON metadata files" option can now be configured using command-line arguments https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/7 https://github.com/Wacheee/GooglePhotosTakeoutHelper/issues/9
  
##### *Previous fixes and improvement (from 3.4.3-wacheee to 3.6.0-wacheee)*
- *if `shortcut` option is selected, shortcut creation will be 10 times faster on Windows platforms (new creation method that avoids using PowerShell). For more details: [TheLastGimbus#390](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/390)*
- *fixed issues with folder names containing emojis  💖🤖🚀on Windows #389*
- *added an interactive option to update the creation times of files in the output folder to match their last modified times at the end of the program (only on Windows) #371*
- *if a media is not in a year folder it establishes one from an album to move it to ALL_PHOTOS correctly. This will move the original media file directly from the album (or one of those albums) to ALL_PHOTOS and create a shortcut in the output album folder (if shortcut option is selected) #261*
- *added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271*
- *added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4*
- *added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355*
- *fixed shortcut issue on Windows platforms #248*
- *added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))*
- *added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums*
  
##### *Limitations (previous fixes):*
- *if album mode is set to duplicate-copy, it will move the album photos to the album folder (as usual), but ALL_PHOTOS will not contain them if the media is not in a year album.*
- *it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.*

### Fork/Alternate version 
#### Windows: 10x faster shortcut creation and other fixes

- if `shortcut` option is selected, shortcut creation will be 10 times faster on Windows platforms (new creation method that avoids using PowerShell). For more details: [TheLastGimbus#390](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/390)
- fixed issues with folder names containing emojis  💖🤖🚀on Windows #389
  
##### *Previous fixes and improvement (from 3.4.3-wacheee to 3.5.2-wacheee)*
- *added an interactive option to update the creation times of files in the output folder to match their last modified times at the end of the program (only on Windows) #371*
- *if a media is not in a year folder it establishes one from an album to move it to ALL_PHOTOS correctly. This will move the original media file directly from the album (or one of those albums) to ALL_PHOTOS and create a shortcut in the output album folder (if shortcut option is selected) #261*
- *added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271*
- *added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4*
- *added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355*
- *fixed shortcut issue on Windows platforms #248*
- *added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))*
- *added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums*
  
##### *Limitations (previous fixes):*
- *if album mode is set to duplicate-copy, it will move the album photos to the album folder (as usual), but ALL_PHOTOS will not contain them if the media is not in a year album.*
- *it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.*

## 3.5.2-wacheee

### Fork/Alternate version 
#### New option to update creation time at the end of program - Windows only

- added an interactive option to update the creation times of files in the output folder to match their last modified times at the end of the program #371

Limitations:
- only works for Windows right now
  
##### *Previous fixes and improvement (from 3.4.3-wacheee to 3.5.1-wacheee)*
- *if a media is not in a year folder it establishes one from an album to move it to ALL_PHOTOS correctly. This will move the original media file directly from the album (or one of those albums) to ALL_PHOTOS and create a shortcut in the output album folder (if shortcut option is selected) #261*
- *added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271*
- *added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4*
- *added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355*
- *fixed shortcut issue on Windows platforms #248*
- *added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))*
- *added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums*
  
##### *Limitations (previous fixes):*
- *if album mode is set to duplicate-copy, it will move the album photos to the album folder (as usual), but ALL_PHOTOS will not contain them if the media is not in a year album.*
- *it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.*

## 3.5.1-wacheee

### Fork/Alternate version 
#### Always move to ALL_PHOTOS even if it is not present in year album

- if a media is not in a year folder it establishes one from an album to move it to ALL_PHOTOS correctly. This will move the original media file directly from the album (or one of those albums) to ALL_PHOTOS and create a shortcut in the output album folder (if shortcut option is selected) #261

Limitations:
- if album mode is set to duplicate-copy, it will move the album photos to the album folder (as usual), but ALL_PHOTOS will not contain them if the media is not in a year album.
  
##### *Previous fixes (3.4.3-wacheee - 3.5.0-wacheee)*
- *added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271*
- *added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4*
- *added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355*
- *fixed shortcut issue on Windows platforms #248*
- *added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))*
- *added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums*
  
##### *Limitations (previous fixes):*
- *it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.*

## 3.5.0-wacheee

### Fork/Alternate version 
#### Convert Pixel Motion Photo files Option - More extensions supported 

- added support for moving or copying files with the following extensions to the output folder: .MP, .MV, .DNG, and .CR2 #381 #324 #180 #271
- added an interactive option to convert Pixel Motion Photo files (.MP or .MV) to .mp4

Limitations:
- it does not fix issues related to reading JSON files (if necessary) for Motion Photo files; however, if the dates are included in the file name (as with Pixel Motion Photos), the correct dates will be established.

## 3.4.3-wacheee

### Fork/Alternate version from original 
#### Bug fixes

- added an option to remove the "supplemental-metadata" suffix from JSON to prevent issues with metadata #353 #355
- fixed shortcut issue on Windows platforms #248
- added more options for date-based folders [year, month, day] #238 (based in this commit [`More granular date folders #299`](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/299/commits/d06fe73101845acd650bc025d2977b96bbd1bf1d))
- added reverse-shortcut option, now you can mantain original photo in album folders and create a shortcut in year albums

## 3.4.3

### Just a few patches ❤️‍🩹

- put stuff in `date-unknown` also when not div-to-dates - #245
- fix extras detection on mac - #243
- add note to not worry about album finding ;)
- nice message when trying to run interactive on headless

## 3.4.2

### Bug fixes again 🐛

- (maybe?) fix weird windoza trailing spaces in folder names (literally wtf??) - #212
  
  Not sure about this one so hope there will be no day-1 patch 😇🙏

- update to Dart 3 🔥
- recognize `.mts` files as videos, unlike Apache 😒 - #223
- change shortcuts/symlinks to relative so it doesn't break on folder move 🤦 - #232
- don't fail on set-file-modification errors - turns out there are lot of these - #229

### Happy takeouts 👽

## 3.4.1

- Lot of serious bug fixes
  - Interactive unzipping was disabled because it sometimes lost *a lot of* photos ;_;
    
    Sorry if anyone lost anything - now I made some visual instruction on how to unzip
  - Gracefully handle powershell fail - it fails with non-ascii names :(
- Great improvement on json matching - now, my 5k Takeout has 100% matches!

## 3.4.0

### Albums 🎉

It finally happened everyone! It wasn't easy, but I think I nailed it and everything should perfectly 👌

You get **_🔥FOUR🔥_** different options on how you want your albums 😱 - detailed descriptions about them is at: https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/discussions/187#discussion-4980576

(This also automatically nicely covers Trash/Archive, so previous solution that originally closed the https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/138 was replaced)

### Happy Take-outing 🥳 

## 3.3.5

- Address #178 issues in logs - instructions on what to do

  Sorry but this is all i can do for now :( we may get actual fix if https://github.com/brendan-duncan/archive/pull/244 ever moves further

## 3.3.4

- New name-guess patterns from @matt-boris <3
- Support 19**-s and 18**-s while name guessing
  > First camera was invented in 1839. I don't underestimate you guys anymore :eyes:
- Fix path errors on windoza while unzipping #172
- Fix #175 bad guessing json files with `...(1)` stuff

## 3.3.3

- Fix memory crashes :D
- nicer names for split-to-dates thanks to @denouche #168 <3

## 3.3.2

- Bump SDK and dependencies

## 3.3.1

### Fix bugs introduced in `v3.3.0` 🤓

- #147 Support `.tgz` files too
- #145 **DON'T** use ram memory equal to zip file thanks to `asyncWrite: true` flag 🙃
- #143 don't crash when encoding is other than `utf8` 🍰
- #136 #144 - On windzoa, set time to 1970 if it's before that - would love to *actually* fix this, but Dart doesn't let me :/

## 3.3.0

- Fix #143 - issues when encoding is not utf8 - sadly, others are still not supported, just skipped
- Ask for divide-to-folders in interactive
- Close #138 - support Archive/Trash folders!

  Implementation of this is a bit complicated, so may break, but should work 99% times
- Fix #134 - nicely tell user what to do when no "year folders" instead of exceptions
- Fix #92 - Much better json finding!
  
  It now should find all of those `...-edited(1).jpg.json` - this also makes it faster because it rarely falls back to reading exif, which is slower
- More small fixes and refactors

### Enjoy even faster and more stable `gpth` everyone 🥳🥳🥳

## 3.2.0

- Brand new ✨interactive mode✨ - just double click 🤘
  - `gpth` now uses 💅discontinued💅 [`file_picker_desktop`](https://pub.dev/packages/file_picker_desktop) to launch pickers for user to select output folder and input...
  - ...zips 🤐! because it also decompresses the takeouts for you! (People had ton of trouble of how to join them etc - no worries anymore!)
- Donation link

## 3.1.1

- Code sign windoza exe with self-made cert

## 3.1.0

- Added `--divide-to-dates` 🎉

## 3.0.0

- Dart!
- Speed
- Consistency - it is well known what script does, what does it copy and what not
- Stable album detection (tho still don't know what to do with it)
- [Testing!](https://youtu.be/UGSgpvjHp9o?t=292)
- Better json matching
- `--guess-from-name` is now a default
- `--skip-extras-harder` is missing for now
- `--divide-to-dates` is missing for now
- End-to-end tests are gone, but they're not as required since we have a lod of Units instead 👍

</details>