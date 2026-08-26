// Service - ExtractDateService (new)
import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth_neo/gpth_lib_exports.dart';

class ExtractDateService with LoggerMixin {
  const ExtractDateService();

  /// Executes the full Step 4 business logic (moved from the wrapper's execute).
  /// Preserves original behavior, logging, progress bar, stats and outputs.
  Future<ExtractDateSummary> extractDates(
    final ProcessingContext context,
  ) async {
    final sw = Stopwatch()..start();

    logPrint('[Step 4/8] Extracting metadata (this may take a while)...');

    final collection = context.mediaCollection;

    // Get and print maxConcurrency
    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );
    logPrint('[Step 4/8] Starting $maxConcurrency threads (exif concurrency)');

    // Build extractor callables bound to File (as in your config), but we will decide
    // per extractor whether to probe primary only (EXIF) or primary+secondaries (others).
    final fileExtractors = context.config.dateExtractors;

    // Map extractor index to the proper DateTimeExtractionMethod (kept order-compatible with your config)
    final extractorMethods = <DateTimeExtractionMethod>[
      DateTimeExtractionMethod.json,
      DateTimeExtractionMethod.exif,
      DateTimeExtractionMethod.guess,
      DateTimeExtractionMethod.jsonTryHard,
      DateTimeExtractionMethod.folderYear,
    ];

    DateAccuracy accuracyFor(final DateTimeExtractionMethod method) {
      switch (method) {
        case DateTimeExtractionMethod.json:
          return DateAccuracy.fromInt(1);
        case DateTimeExtractionMethod.exif:
          return DateAccuracy.fromInt(2);
        case DateTimeExtractionMethod.guess:
          return DateAccuracy.fromInt(3);
        case DateTimeExtractionMethod.jsonTryHard:
          return DateAccuracy.fromInt(4);
        case DateTimeExtractionMethod.folderYear:
          return DateAccuracy.fromInt(5);
        default:
          return DateAccuracy.fromInt(99);
      }
    }

    // Stats + progress (same semantics as before)
    final extractionStats = <DateTimeExtractionMethod, int>{};
    var completed = 0;
    final progressBar = FillingBar(
      desc: '[ INFO  ] [Step 4/8] Processing media files',
      total: collection.length,
      width: 50,
      percentage: true,
    );

    for (int i = 0; i < collection.length; i += maxConcurrency) {
      final batch = collection
          .asList()
          .skip(i)
          .take(maxConcurrency)
          .toList(growable: false);
      final batchStartIndex = i;

      final futures = batch.asMap().entries.map((final entry) async {
        final batchIndex = entry.key;
        final media = entry.value;
        final actualIndex = batchStartIndex + batchIndex;

        // If already has a date, keep it (parity with previous behavior)
        if (media.dateTaken != null) {
          final method =
              media.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
          return {
            'index': actualIndex,
            'mediaFile': media,
            'extractionMethod': method,
          };
        }

        DateTime? foundDate;
        DateTimeExtractionMethod methodUsed = DateTimeExtractionMethod.none;
        DMSCoordinates? foundGps;

        // Iterate extractors in priority order
        for (
          int extractorIndex = 0;
          extractorIndex < fileExtractors.length;
          extractorIndex++
        ) {
          final method = extractorIndex < extractorMethods.length
              ? extractorMethods[extractorIndex]
              : DateTimeExtractionMethod.guess;
          final extractor = fileExtractors[extractorIndex];

          final isJsonMethod =
              method == DateTimeExtractionMethod.json ||
              method == DateTimeExtractionMethod.jsonTryHard;

          try {
            if (isJsonMethod) {
              // Use the combined extractor so JSON is read only once for both
              // date and GPS (avoids a second read by Step 7).
              // Uses the cached sidecar path from Step 2 when available,
              // skipping the expensive findJsonForFileWithConfidence lookup.
              final tryhard = method == DateTimeExtractionMethod.jsonTryHard;
              final result = await extractAllFromJsonCached(
                media.primaryFile,
                tryhard: tryhard,
              );
              if (result.date != null) {
                foundDate = result.date;
                methodUsed = method;
              }
              // Always capture GPS from JSON if present, even if date was
              // already found by a previous extractor.
              if (result.gps != null && foundGps == null) {
                foundGps = result.gps;
              }
              // If we got a date, stop looking; otherwise try secondaries.
              if (foundDate != null) break;
              for (final fe in media.secondaryFiles) {
                final r2 = await extractAllFromJsonCached(fe, tryhard: tryhard);
                if (r2.date != null) {
                  foundDate = r2.date;
                  methodUsed = method;
                }
                if (r2.gps != null && foundGps == null) foundGps = r2.gps;
                if (foundDate != null) break;
              }
              if (foundDate != null) break;
            } else if (method == DateTimeExtractionMethod.exif) {
              // EXIF: only check primaryFile to avoid redundant work on secondaries
              foundDate = await extractor(media.primaryFile.asFile());
              if (foundDate != null) {
                methodUsed = method;
                break;
              }
            } else {
              // Non-EXIF/non-JSON (guess, folderYear, etc.): try primary, then secondaries
              foundDate = await extractor(media.primaryFile.asFile());
              if (foundDate != null) {
                methodUsed = method;
                break;
              }
              for (final fe in media.secondaryFiles) {
                foundDate = await extractor(fe.asFile());
                if (foundDate != null) {
                  methodUsed = method;
                  break;
                }
              }
              if (foundDate != null) break;
            }
          } catch (e) {
            logWarning(
              'Extractor failed for ${_safePath(media.primaryFile.asFile())}: $e',
              forcePrint: true,
            );
          }
        }

        // Build updated entity with entity-level date/accuracy/method/gps
        final DateAccuracy acc = accuracyFor(
          foundDate != null ? methodUsed : DateTimeExtractionMethod.none,
        );
        MediaEntity updated = media.withDate(
          dateTaken: foundDate ?? media.dateTaken,
          dateAccuracy: acc,
          dateTimeExtractionMethod: foundDate != null
              ? methodUsed
              : DateTimeExtractionMethod.none,
        );
        if (foundGps != null) {
          updated = updated.withGpsCoordinates(foundGps);
        }

        if (foundDate != null) {
          logDebug(
            '[Step 4/8] Date extracted for ${media.primaryFile.path}: $foundDate (method: ${methodUsed.name}, accuracy: ${acc.value})',
          );
        }

        return {
          'index': actualIndex,
          'mediaFile': updated,
          'extractionMethod': foundDate != null
              ? methodUsed
              : DateTimeExtractionMethod.none,
        };
      });

      final results = await Future.wait(futures);

      // Apply results & stats update
      for (final r in results) {
        final idx = r['index'] as int;
        final updated = r['mediaFile'] as MediaEntity;
        final method = r['extractionMethod'] as DateTimeExtractionMethod;

        collection.replaceAt(idx, updated);
        extractionStats[method] = (extractionStats[method] ?? 0) + 1;

        completed++;
        progressBar.update(completed);
      }
    }

    print(''); // print to force new line after progress bar
    logPrint('[Step 4/8] Date extraction completed');

    // READ-EXIF Telemetry Summary (seconds)
    ExifDateExtractor.dumpStats(
      reset: true,
      loggerMixin: this,
      exiftoolFallbackEnabled:
          ServiceContainer
              .instance
              .globalConfig
              .fallbackToExifToolOnNativeMiss ==
          true,
    );

    // Print stats
    logPrint('[Step 4/8] === Date Extraction Summary ===');
    final byName = <String, int>{
      for (final e in extractionStats.entries) e.key.name: e.value,
    };
    const order = [
      'json',
      'exif',
      'guess',
      'jsonTryHard',
      'folderYear',
      'none',
    ];
    for (final k in order) {
      logPrint('[Step 4/8]     $k: ${byName[k] ?? 0} files');
    }

    sw.stop();
    return ExtractDateSummary(
      message: 'Extracted dates for ${collection.length} files',
      extractionStats: extractionStats,
      processedMedia: collection.length,
    );
  }

  String _safePath(final File f) {
    try {
      return f.path;
    } catch (_) {
      return '<unknown-file>';
    }
  }
}

class ExtractDateSummary {
  const ExtractDateSummary({
    required this.message,
    required this.extractionStats,
    required this.processedMedia,
  });

  final String message;
  final Map<DateTimeExtractionMethod, int> extractionStats;
  final int processedMedia;

  Map<String, dynamic> toMap() => {
    'extractionStats': extractionStats,
    'processedMedia': processedMedia,
  };
}
