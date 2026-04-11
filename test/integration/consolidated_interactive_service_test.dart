import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

/// Mock presenter for testing that captures interactions
class MockInteractivePresenter extends InteractivePresenterService {
  MockInteractivePresenter()
    : super(enableSleep: false, enableInputValidation: false);
  final List<String> _prompts = [];
  final List<String> _inputs = <String>[];
  final List<String> _messages = [];
  int _inputIndex = 0;

  List<String> get prompts => List.unmodifiable(_prompts);
  List<String> get messages => List.unmodifiable(_messages);

  void setInputs(final List<String> inputs) {
    _inputs.clear();
    _inputs.addAll(inputs);
    _inputIndex = 0;
  }

  @override
  Future<String> readUserInput() async {
    if (_inputIndex < _inputs.length) {
      return _inputs[_inputIndex++];
    }
    throw StateError(
      'MockInteractivePresenter ran out of scripted inputs. '
      'Provide more inputs for this test case.',
    );
  }

  @override
  void showPressEnterPrompt() {
    _prompts.add('press_enter');
  }

  @override
  Future<void> promptForDateDivision() async {
    _prompts.add('date_division');
  }

  @override
  Future<void> promptForAlbumBehavior() async {
    _prompts.add('album_behavior');
  }

  @override
  void showAlbumOption(
    final int index,
    final String key,
    final String description,
  ) {
    _messages.add('album_option: $index $key $description');
  }

  @override
  Future<void> showAlbumChoice(final String choice) async {
    _messages.add('album_choice: $choice');
  }

  @override
  Future<void> showGreeting() async {
    _messages.add('greeting_shown');
  }

  @override
  Future<void> showNothingFoundMessage() async {
    _messages.add('nothing_found_shown');
  }

  @override
  Future<void> showUserSelection(
    final String input,
    final String selectedValue,
  ) async {
    String displayValue = selectedValue;
    if (input.isEmpty) {
      displayValue = '$selectedValue (default)';
    }
    _messages.add('user_selection: $displayValue');
  }

  void clearHistory() {
    _prompts.clear();
    _messages.clear();
    _inputs.clear();
    _inputIndex = 0;
  }
}

void main() {
  group('ConsolidatedInteractiveService', () {
    late ConsolidatedInteractiveService service;
    late MockInteractivePresenter mockPresenter;
    late GlobalConfigService globalConfig;

    setUp(() {
      globalConfig = GlobalConfigService();
      mockPresenter = MockInteractivePresenter();
      service = ConsolidatedInteractiveService(
        globalConfig: globalConfig,
        presenter: mockPresenter,
      );
    });

    test('should create ConsolidatedInteractiveService instance', () {
      expect(service, isA<ConsolidatedInteractiveService>());
    });

    group('Utility operations', () {
      test('should sleep for specified duration', () async {
        final stopwatch = Stopwatch()..start();
        await service.sleep(0.1); // 100ms
        stopwatch.stop();

        // Allow some tolerance for timing - the sleep should take around 100ms
        // but we're lenient due to system timing variations
        expect(stopwatch.elapsedMilliseconds, greaterThan(80));
        expect(stopwatch.elapsedMilliseconds, lessThan(200));
      });

      test('should show press enter prompt', () {
        service.pressEnterToContinue();
        expect(mockPresenter.prompts, contains('press_enter'));
      });
    });

    group('Date division prompt', () {
      test('should ask for date division with valid input', () async {
        mockPresenter.setInputs(['1']);

        final result = await service.askDivideDates();

        expect(result, equals(1)); // Input '1' maps to option 1 (year folders)
        expect(mockPresenter.prompts, contains('date_division'));
        expect(
          mockPresenter.messages,
          contains('user_selection: year folders'),
        );
      });
      test('should handle year division option', () async {
        mockPresenter.setInputs(['2']);

        final result = await service.askDivideDates();

        expect(
          result,
          equals(2),
        ); // Input '2' maps to option 2 (year/month folders)
        expect(
          mockPresenter.messages,
          contains('user_selection: year/month folders'),
        );
      });
      test('should handle year/month division option', () async {
        mockPresenter.setInputs(['3']);

        final result = await service.askDivideDates();

        expect(
          result,
          equals(3),
        ); // Input '3' maps to option 3 (year/month/day folders)
        expect(
          mockPresenter.messages,
          contains('user_selection: year/month/day folders'),
        );
      });
      test('should handle year/month/day division option', () async {
        mockPresenter.setInputs(['3']);

        final result = await service.askDivideDates();
        expect(
          result,
          equals(3),
        ); // Input '3' maps to option 3 (year/month/day folders)
        expect(
          mockPresenter.messages,
          contains('user_selection: year/month/day folders'),
        );
      });
      test('should retry on invalid input', () async {
        mockPresenter.setInputs(['invalid', '99', '1']);

        final result = await service.askDivideDates();

        expect(result, equals(1)); // Input '1' maps to option 1 (year folders)
      });

      test('should handle default (empty) input', () async {
        mockPresenter.setInputs(['']);

        final result = await service.askDivideDates();

        expect(
          result,
          equals(0),
        ); // Empty input maps to option 0 (one big folder)
        expect(
          mockPresenter.messages,
          contains('user_selection: one big folder (default)'),
        );
      });
    });

    group('Album behavior prompt', () {
      test('should ask for album behavior with valid input', () async {
        // Input '0' should select the first album option
        mockPresenter.setInputs(['0']);

        final result = await service.askAlbums();

        expect(result, isA<String>());
        expect(mockPresenter.prompts, contains('album_behavior'));

        // Should show album options
        expect(
          mockPresenter.messages
              .where((final m) => m.startsWith('album_option:'))
              .length,
          greaterThan(0),
        );
      });

      test('should retry on invalid album input', () async {
        mockPresenter.setInputs(['invalid', '999', '0']);

        final result = await service.askAlbums();

        expect(result, isA<String>());
      });
    });

    group('Boolean prompts', () {
      test('should ask for clean output', () async {
        mockPresenter.setInputs(['1']);

        final result = await service.askForCleanOutput();

        expect(result, isTrue);
      });

      test('should ask for Pixel MP transform', () async {
        mockPresenter.setInputs(['n']);

        final result = await service.askTransformPixelMP();

        expect(result, isFalse);
      });

      test('should ask for creation time update', () async {
        mockPresenter.setInputs(['yes']);

        final result = await service.askChangeCreationTime();

        expect(result, isTrue);
      });

      test('should ask for file size limit', () async {
        mockPresenter.setInputs(['2']);

        final result = await service.askIfLimitFileSize();

        expect(result, isTrue);
      });

      test('should ask for unzip option', () async {
        mockPresenter.setInputs(['1']);

        final result = await service.askIfUnzip();

        expect(result, isTrue);
      });

      test('should ask yes/no questions', () async {
        mockPresenter.setInputs(['y']);

        final result = await service.askYesNo('Test question?');

        expect(result, isTrue);
      });
    });
    group('Extension fixing prompt', () {
      test('should ask for extension fixing mode', () async {
        mockPresenter.setInputs(['1']);

        final result = await service.askFixExtensions();

        expect(result, equals('standard'));
      });

      test('should handle conservative option', () async {
        mockPresenter.setInputs(['2']);

        final result = await service.askFixExtensions();

        expect(result, equals('conservative'));
      });

      test('should handle solo option', () async {
        mockPresenter.setInputs(['3']);

        final result = await service.askFixExtensions();

        expect(result, equals('solo'));
      }, tags: ['flaky']);

      test('should handle none option', () async {
        mockPresenter.setInputs(['4']);

        final result = await service.askFixExtensions();

        expect(result, equals('none'));
      }, tags: ['flaky']);
      test('should handle default (empty input)', () async {
        mockPresenter.setInputs(['']);

        final result = await service.askFixExtensions();

        expect(result, equals('standard'));
      });

      test('should retry on invalid extension input', () async {
        mockPresenter.setInputs(['invalid', '99', '1']);

        final result = await service.askFixExtensions();

        expect(result, equals('standard')); // Input '1' maps to standard
      });
    });

    group('User input operations', () {
      test('should read user input', () async {
        mockPresenter.setInputs(['test input']);

        final result = await service.readUserInput();

        expect(result, equals('test input'));
      });

      test('should prompt user with custom message', () async {
        mockPresenter.setInputs(['response']);

        final result = await service.promptUser('Custom prompt');

        expect(result, equals('response'));
      });
    });

    group('Message display', () {
      test('should show greeting', () async {
        await service.showGreeting();

        expect(mockPresenter.messages, contains('greeting_shown'));
      });

      test('should show nothing found message', () async {
        await service.showNothingFoundMessage();

        expect(mockPresenter.messages, contains('nothing_found_shown'));
      });
    });

    group('Integration tests', () {
      test('should handle complete date division workflow', () async {
        mockPresenter.setInputs(['invalid', '0']);

        final result = await service.askDivideDates();

        expect(result, equals(0));
        expect(mockPresenter.prompts, contains('date_division'));
        expect(
          mockPresenter.messages.any((final m) => m.contains('one big folder')),
          isTrue,
        );
      });

      test('should handle complete album workflow', () async {
        mockPresenter.setInputs(['0']);

        final result = await service.askAlbums();

        expect(result, isA<String>());
        expect(mockPresenter.prompts, contains('album_behavior'));
      });

      test('should handle retry logic for yes/no questions', () async {
        mockPresenter.setInputs(['invalid', 'maybe', 'n']);

        final result = await service.askYesNo('Test question?');

        expect(result, isFalse);
      });
      test('should handle boolean input variations', () async {
        // Test askForCleanOutput with 'yes' input - this expects '1', not 'yes'
        mockPresenter.setInputs(['1']);
        expect(await service.askForCleanOutput(), isTrue);
      });

      test('should handle more boolean input variations', () async {
        // Test askTransformPixelMP with 'no' input
        mockPresenter.setInputs(['no']);
        expect(await service.askTransformPixelMP(), isFalse);
      });

      test('should handle creation time boolean variations', () async {
        // Test askChangeCreationTime with 'y' input
        mockPresenter.setInputs(['y']);
        expect(await service.askChangeCreationTime(), isTrue);
      });
    });
  });
}
