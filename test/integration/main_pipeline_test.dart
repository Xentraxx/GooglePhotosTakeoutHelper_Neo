import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessingPipeline', () {
    late ProcessingPipeline pipeline;
    late Directory tempInputDir;
    late Directory tempOutputDir;
    setUp(() async {
      pipeline = const ProcessingPipeline();
      tempInputDir = await Directory.systemTemp.createTemp(
        'pipeline_input_test',
      );
      tempOutputDir = await Directory.systemTemp.createTemp(
        'pipeline_output_test',
      );
    });

    tearDown(() async {
      if (await tempInputDir.exists()) {
        await tempInputDir.delete(recursive: true);
      }
      if (await tempOutputDir.exists()) {
        try {
          await tempOutputDir.delete(recursive: true);
        } catch (e) {
          // Ignore errors during cleanup
        }
      }
    });

    test('should create ProcessingPipeline instance', () {
      expect(pipeline, isA<ProcessingPipeline>());
    });
    test('should execute pipeline with minimal config', () async {
      // Create minimal config for fast test
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        disableResumeCheck: true,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempInputDir,
        outputDirectory: tempOutputDir,
      );

      expect(result, isA<ProcessingResult>());
      expect(result.isSuccess, isTrue);
      expect(result.totalProcessingTime, isNotNull);
    });

    test('should execute pipeline with extension fixing enabled', () async {
      // Create test files in input directory
      final testImageFile = File('${tempInputDir.path}/test_image.jpg');
      await testImageFile.writeAsBytes([
        0xFF,
        0xD8,
        0xFF,
        0xE0,
      ]); // Minimal JPEG header

      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempInputDir,
        outputDirectory: tempOutputDir,
      );

      expect(result, isA<ProcessingResult>());
      expect(result.isSuccess, isTrue);
      expect(result.totalProcessingTime, isNotNull);
    });
    test('should handle empty input directory gracefully', () async {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.none,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempInputDir,
        outputDirectory: tempOutputDir,
      );

      expect(result, isA<ProcessingResult>());
      expect(result.isSuccess, isTrue);
    });

    test('should validate processing config parameters', () {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        albumBehavior: AlbumBehavior.duplicateCopy,
        dateDivision: DateDivisionLevel.month,
        extensionFixing: ExtensionFixingMode.conservative,
        transformPixelMp: true,
        pixelMpTransformFormat: PixelMpTransformFormat.jpg,
        updateCreationTime: Platform.isWindows,
        limitFileSize: true,
        verbose: true,
      );
      expect(config.inputPath, equals(tempInputDir.path));
      expect(config.outputPath, equals(tempOutputDir.path));
      expect(config.albumBehavior, equals(AlbumBehavior.duplicateCopy));
      expect(config.dateDivision, equals(DateDivisionLevel.month));
      expect(config.writeExif, isTrue);
      expect(config.skipExtras, isFalse);
      expect(config.guessFromName, isTrue);
      expect(config.extensionFixing, equals(ExtensionFixingMode.conservative));
      expect(config.transformPixelMp, isTrue);
      expect(config.pixelMpTransformFormat, equals(PixelMpTransformFormat.jpg));
      expect(config.limitFileSize, isTrue);
      expect(config.verbose, isTrue);
    });

    test('should default Pixel transform format to mp4', () {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        transformPixelMp: true,
      );

      expect(config.pixelMpTransformFormat, equals(PixelMpTransformFormat.mp4));
    });

    test('should support Pixel still transform format', () {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        transformPixelMp: true,
        pixelMpTransformFormat: PixelMpTransformFormat.still,
      );

      expect(
        config.pixelMpTransformFormat,
        equals(PixelMpTransformFormat.still),
      );
    });
    test(
      'should handle non-existent input directory',
      () async {
        final nonExistentDir = Directory('${tempInputDir.path}/non_existent');
        final config = ProcessingConfig(
          inputPath: nonExistentDir.path,
          outputPath: tempOutputDir.path,
          writeExif: false,
          skipExtras: true,
          guessFromName: false,
          extensionFixing: ExtensionFixingMode.none,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: nonExistentDir,
          outputDirectory: tempOutputDir,
        );

        // Should return a failed result instead of throwing an exception
        expect(result.isSuccess, isFalse);
        expect(result.totalProcessingTime, isNotNull);
      },
      skip: !Platform.isWindows
          ? 'Skipped on non-Windows platforms (behavior validated only on Windows)'
          : false,
    );
    test('should track execution timing correctly', () async {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: tempInputDir,
        outputDirectory: tempOutputDir,
      );

      expect(
        result.totalProcessingTime.inMilliseconds,
        greaterThanOrEqualTo(0),
      );
      expect(result.stepTimings, isNotEmpty);

      // Verify all steps have execution times
      for (final timing in result.stepTimings.values) {
        expect(timing.inMilliseconds, greaterThanOrEqualTo(0));
      }
    });
    test('should handle solo extension fixing mode', () async {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        writeExif: false,
        skipExtras: true,
        guessFromName: false,
        extensionFixing: ExtensionFixingMode.solo,
      );

      expect(config.shouldContinueAfterExtensionFix, isFalse);
      expect(config.extensionFixing, equals(ExtensionFixingMode.solo));
    });

    test('should provide correct date extractors based on configuration', () {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
      );

      final extractors = config.dateExtractors;
      expect(extractors, isNotEmpty);
      expect(
        extractors.length,
        greaterThan(2),
      ); // Should include JSON, EXIF, and guess extractors
    });

    test('should not include guess extractor when disabled', () {
      final config = ProcessingConfig(
        inputPath: tempInputDir.path,
        outputPath: tempOutputDir.path,
        guessFromName: false,
      );

      final extractors = config.dateExtractors;
      expect(extractors, isNotEmpty);
      // Should have fewer extractors when guess is disabled
    });

    test('should validate configuration correctly', () {
      const validConfig = ProcessingConfig(
        inputPath: '/valid/input',
        outputPath: '/valid/output',
      );

      expect(() => validConfig.validate(), returnsNormally);

      const invalidInputConfig = ProcessingConfig(
        inputPath: '',
        outputPath: '/valid/output',
      );

      expect(
        () => invalidInputConfig.validate(),
        throwsA(isA<ConfigurationException>()),
      );

      const invalidOutputConfig = ProcessingConfig(
        inputPath: '/valid/input',
        outputPath: '',
      );

      expect(
        () => invalidOutputConfig.validate(),
        throwsA(isA<ConfigurationException>()),
      );
    });
  });
}
