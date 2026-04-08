/// Constants related to EXIF processing
library;

/// Human-readable format label keyed by file extension (dot-prefixed, lowercase).
/// Also used to check whether an extension is unsupported for ExifTool writes.
const Map<String, String> exifToolUnsupportedExtensionLabels = {
  '.avi': 'AVI',
  '.mpg': 'MPEG',
  '.mpeg': 'MPEG',
  '.mts': 'MTS',
  '.m2ts': 'MTS',
  '.wmv': 'WMV',
  '.bmp': 'BMP',
};

/// Human-readable format label keyed by MIME type.
/// Also used to check whether a MIME type is unsupported for ExifTool writes.
const Map<String, String> exifToolUnsupportedMimeLabels = {
  'video/x-msvideo': 'AVI',
  'video/mpeg': 'MPEG',
  'video/mp2t': 'MTS',
  'model/vnd.mts': 'MTS',
  'video/x-ms-wmv': 'WMV',
  'image/bmp': 'BMP',
};

/// MIME types supported by the native exif_reader library
///
/// This list represents formats that can be processed using the fast native
/// exif_reader library instead of the slower ExifTool external process.
/// Based on https://pub.dev/packages/exif_reader documentation.
const Set<String> supportedNativeExifMimeTypes = {
  'image/jpeg',
  'image/tiff',
  'image/heic',
  'image/png',
  'image/webp',
  'image/jxl',
  'image/x-sony-arw',
  'image/x-canon-cr2',
  'image/x-canon-cr3',
  'image/x-canon-crw',
  'image/x-nikon-nef',
  'image/x-nikon-nrw',
  'image/x-panasonic-rw2',
  'image/x-fuji-raf',
  'image/x-adobe-dng',
  'image/x-raw',
  'image/tiff-fx',
  'image/x-portable-anymap',
};
