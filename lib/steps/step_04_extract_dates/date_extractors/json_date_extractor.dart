import 'dart:convert';
import 'dart:io';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Finds corresponding json file with info from media file and gets 'photoTakenTime' from it
Future<DateTime?> jsonDateTimeExtractor(
  final File file, {
  final bool tryhard = false,
}) async {
  final File? jsonFile = await jsonForFile(file, tryhard: tryhard);
  if (jsonFile == null) return null;
  try {
    final dynamic data = jsonDecode(await jsonFile.readAsString());
    final int epoch = int.parse(data['photoTakenTime']['timestamp'].toString());
    return DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
  } on FormatException catch (_) {
    // this is when json is bad
    return null;
  } on FileSystemException catch (_) {
    // this happens for issue #143
    // "Failed to decode data using encoding 'utf-8'"
    // maybe this will self-fix when dart itself support more encodings
    return null;
  } on NoSuchMethodError catch (_) {
    // this is when tags like photoTakenTime aren't there
    return null;
  }
}

/// Attempts to find the corresponding JSON file for a media file
///
/// Delegates to JsonMetadataMatcherService service for the actual matching logic.
/// This function maintains backward compatibility with existing code.
///
/// [file] Media file to find JSON for
/// [tryhard] If true, uses more aggressive matching strategies
/// Returns the JSON file if found, null otherwise
Future<File?> jsonForFile(
  final File file, {
  required final bool tryhard,
}) async => JsonMetadataMatcherService.findJsonForFile(file, tryhard: tryhard);

/// Reads the JSON sidecar for [file] exactly once and returns both the
/// photo-taken datetime and GPS coordinates.  Combines what previously
/// required two separate `jsonDateTimeExtractor` + `jsonCoordinatesExtractor`
/// calls (and therefore two file reads).
///
/// **Issue #139 — cross-photo contamination guard:** date **and** GPS are only
/// returned when the matched sidecar is the file's *own* (`isOwnSidecar`).
/// Heuristic matches that can point at a *different* photo's sidecar
/// (`-edited` removal, cross-extension MP4↔HEIC/JPG, numbered cross-extension)
/// yield `(null, null)` so the caller falls through to the next extractor
/// (EXIF → guess → folderYear). A related photo's date is not acceptable for
/// this file — that was the mis-dated-video symptom in issue #139.
Future<({DateTime? date, DMSCoordinates? gps})> extractAllFromJson(
  final File file, {
  final bool tryhard = false,
}) async {
  final match = await JsonMetadataMatcherService.findJsonForFileWithConfidence(
    file,
    tryhard: tryhard,
  );
  final File? jsonFile = match.jsonFile;
  if (jsonFile == null) return (date: null, gps: null);
  // A heuristic match can name a different photo's sidecar. Borrowing that
  // photo's date is not acceptable (issue #139), so drop BOTH fields and let
  // the caller fall through to EXIF / guess / folderYear.
  if (!match.isOwnSidecar) return (date: null, gps: null);
  return _extractDateAndGpsFromJsonFile(jsonFile);
}

/// Extracts date and GPS from a JSON sidecar file, using the content cache
/// to avoid redundant reads. This is the shared implementation used by both
/// [extractAllFromJson] (which resolves the sidecar path) and
/// [extractAllFromJsonCached] (which reuses a pre-resolved path).
Future<({DateTime? date, DMSCoordinates? gps})> _extractDateAndGpsFromJsonFile(
  final File jsonFile,
) async {
  final data = await JsonMetadataMatcherService.readJsonContentCached(jsonFile);
  if (data == null) return (date: null, gps: null);

  // --- date ---
  DateTime? date;
  try {
    final int epoch = int.parse(data['photoTakenTime']['timestamp'].toString());
    date = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
  } catch (_) {}

  // --- GPS ---
  DMSCoordinates? fromGeoEntry(final entry) {
    if (entry == null) return null;
    final double? lat = (entry['latitude'] as num?)?.toDouble();
    final double? long = (entry['longitude'] as num?)?.toDouble();
    if (lat == null || long == null) return null;
    if (lat == 0.0 && long == 0.0) return null;
    if (!lat.isFinite || !long.isFinite) return null;
    if (lat < -90 || lat > 90 || long < -180 || long > 180) return null;
    return DMSCoordinates.fromDD(DDCoordinates(latitude: lat, longitude: long));
  }

  DMSCoordinates? gps;
  try {
    gps = fromGeoEntry(data['geoDataExif']) ?? fromGeoEntry(data['geoData']);
  } catch (_) {}

  return (date: date, gps: gps);
}

/// Extracts date and GPS from a JSON sidecar, reusing the sidecar path and
/// confidence flag cached on the [FileEntity] during Step 2 discovery.
///
/// When [fileEntity.jsonSidecarPath] is set, the expensive
/// `findJsonForFileWithConfidence` lookup is skipped entirely. The cached
/// `jsonIsOwnSidecar` flag is used to enforce the issue #139 guard.
///
/// Falls back to [extractAllFromJson] when no cached path is available
/// (e.g. for secondary files that were not processed during Step 2).
Future<({DateTime? date, DMSCoordinates? gps})> extractAllFromJsonCached(
  final FileEntity fileEntity, {
  final bool tryhard = false,
}) async {
  final cachedPath = fileEntity.jsonSidecarPath;
  if (cachedPath != null) {
    // Use the cached sidecar path — skip the expensive lookup.
    final isOwnSidecar = fileEntity.jsonIsOwnSidecar ?? false;
    if (!isOwnSidecar) return (date: null, gps: null);
    return _extractDateAndGpsFromJsonFile(File(cachedPath));
  }
  // No cached path — fall back to the full lookup.
  return extractAllFromJson(fileEntity.asFile(), tryhard: tryhard);
}

/// This is to get coordinates from the json file. Expects media file and finds json.
Future<DMSCoordinates?> jsonCoordinatesExtractor(
  final File file, {
  final bool tryhard = false,
}) async {
  final File? jsonFile = await jsonForFile(file, tryhard: tryhard);
  if (jsonFile == null) return null;
  try {
    final Map<String, dynamic> data = jsonDecode(await jsonFile.readAsString());

    // Helper to extract valid (non-zero) coords from a geoData-like map entry.
    DMSCoordinates? fromGeoEntry(final entry) {
      if (entry == null) return null;
      final double? lat = (entry['latitude'] as num?)?.toDouble();
      final double? long = (entry['longitude'] as num?)?.toDouble();
      if (lat == null || long == null) return null;
      if (lat == 0.0 && long == 0.0) return null;
      if (!lat.isFinite || !long.isFinite) return null;
      if (lat < -90 || lat > 90 || long < -180 || long > 180) return null;
      return DMSCoordinates.fromDD(
        DDCoordinates(latitude: lat, longitude: long),
      );
    }

    // geoDataExif carries camera-recorded GPS; geoData may be Google-inferred
    // and is often 0,0 when the photo had no manual location set.
    return fromGeoEntry(data['geoDataExif']) ?? fromGeoEntry(data['geoData']);
  } on FormatException catch (_) {
    // this is when json is bad
    return null;
  } on FileSystemException catch (_) {
    // this happens for issue #143
    // "Failed to decode data using encoding 'utf-8'"
    // maybe this will self-fix when dart itself support more encodings
    return null;
  } on NoSuchMethodError catch (_) {
    // this is when tags like geoData aren't there
    return null;
  }
}

/// Extracts partner sharing information from the JSON file
///
/// Returns true if the media was shared by a partner (has googlePhotosOrigin.fromPartnerSharing),
/// false otherwise (including for personal uploads with mobileUpload or other origins)
Future<bool> jsonPartnerSharingExtractor(
  final File file, {
  final bool tryhard = false,
}) async {
  final File? jsonFile = await jsonForFile(file, tryhard: tryhard);
  if (jsonFile == null) return false;
  try {
    final dynamic data = jsonDecode(await jsonFile.readAsString());

    // Check if googlePhotosOrigin exists and has fromPartnerSharing
    final dynamic googlePhotosOrigin = data['googlePhotosOrigin'];
    if (googlePhotosOrigin != null &&
        googlePhotosOrigin is Map<String, dynamic>) {
      return googlePhotosOrigin.containsKey('fromPartnerSharing');
    }

    return false;
  } on FormatException catch (_) {
    // this is when json is bad
    return false;
  } on FileSystemException catch (_) {
    // this happens for issue #143
    // "Failed to decode data using encoding 'utf-8'"
    // maybe this will self-fix when dart itself support more encodings
    return false;
  } on NoSuchMethodError catch (_) {
    // this is when tags like googlePhotosOrigin aren't there
    return false;
  }
}
