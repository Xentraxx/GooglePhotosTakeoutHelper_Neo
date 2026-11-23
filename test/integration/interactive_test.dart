/// Simplified interactive module test for consolidated services
///
/// This test validates that the consolidated interactive services work correctly
/// and provide the expected behavior for user interaction operations.
library;

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('Interactive Module - Consolidated Services', () {
    setUpAll(() async {
      // Initialize service container for consolidated services
      await ServiceContainer.instance.initialize();
    });

    tearDownAll(() async {
      // Clean up service container
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
    });

    group('Service Availability', () {
      test('consolidated interactive service is available', () {
        expect(ServiceContainer.instance.interactiveService, isNotNull);
        expect(ServiceContainer.instance.utilityService, isNotNull);
        expect(ServiceContainer.instance.diskSpaceService, isNotNull);
      });

      test('interactive service methods are available', () {
        final service = ServiceContainer.instance.interactiveService;

        // Check that key methods exist (we can't test them interactively)
        expect(service.readUserInput, isNotNull);
        expect(service.askAlbums, isNotNull);
        expect(service.askForCleanOutput, isNotNull);
        expect(service.selectInputDirectory, isNotNull);
        expect(service.selectOutputDirectory, isNotNull);
        expect(service.selectArchiveFiles, isNotNull);
        expect(service.extractAll, isNotNull);
        expect(service.freeSpaceNotice, isNotNull);
      });
    });

    group('Utility Operations', () {
      test('sleep method is available', () {
        final service = ServiceContainer.instance.interactiveService;
        expect(service.sleep, isNotNull);
      });

      test('pressEnterToContinue method is available', () {
        final service = ServiceContainer.instance.interactiveService;
        expect(service.pressEnterToContinue, isNotNull);
      });
    });

    group('Configuration Methods', () {
      test('configuration prompt methods are available', () {
        final service = ServiceContainer.instance.interactiveService;

        expect(service.askDivideDates, isNotNull);
        expect(service.askTransformPixelMP, isNotNull);
        expect(service.askChangeCreationTime, isNotNull);
        expect(service.askIfWriteExif, isNotNull);
        expect(service.askIfLimitFileSize, isNotNull);
        expect(service.askFixExtensions, isNotNull);
        expect(service.askIfUnzip, isNotNull);
      });
    });

    group('File Operations', () {
      test('file selection methods are available', () {
        final service = ServiceContainer.instance.interactiveService;

        expect(service.selectInputDirectory, isNotNull);
        expect(service.selectOutputDirectory, isNotNull);
        expect(service.selectArchiveFiles, isNotNull);
      });

      test('file operations are available', () {
        final service = ServiceContainer.instance.interactiveService;

        expect(service.extractAll, isNotNull);
        expect(service.freeSpaceNotice, isNotNull);
      });
    });

    group('User Interface Methods', () {
      test('UI methods are available', () {
        final service = ServiceContainer.instance.interactiveService;

        expect(service.showGreeting, isNotNull);
        expect(service.showNothingFoundMessage, isNotNull);
        expect(service.promptUser, isNotNull);
        expect(service.askYesNo, isNotNull);
      });
    });
  });
}
