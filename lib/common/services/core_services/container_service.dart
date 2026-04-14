import 'package:gpth_neo/gpth_lib_exports.dart';

/// Service container for dependency injection
///
/// Manages the lifecycle of all application services and provides
/// centralized configuration and initialization.
class ServiceContainer {
  ServiceContainer._();

  // Use nullable fields to allow re-initialization if needed.
  GlobalConfigService? _globalConfig;
  LoggingService? _loggingService;
  FormattingService? _utilityService;
  ConsolidatedDiskSpaceService? _diskSpaceService;
  ConsolidatedInteractiveService? _interactiveService;
  MergeMediaEntitiesService? _duplicateDetectionService;
  AlbumRelationshipService? _albumRelationshipService;

  /// ExifTool service (may be null if not found)
  ExifToolService? exifTool;

  bool _isInitialized = false;

  static ServiceContainer? _instance;

  /// Singleton accessor
  static ServiceContainer get instance {
    _instance ??= ServiceContainer._();
    return _instance!;
  }

  // ── Safe getters ───────────────────────────────────────────────────────────

  GlobalConfigService get globalConfig {
    if (_globalConfig == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _globalConfig!;
  }

  LoggingService get loggingService {
    if (_loggingService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _loggingService!;
  }

  FormattingService get utilityService {
    if (_utilityService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _utilityService!;
  }

  ConsolidatedDiskSpaceService get diskSpaceService {
    if (_diskSpaceService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _diskSpaceService!;
  }

  ConsolidatedInteractiveService get interactiveService {
    if (_interactiveService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _interactiveService!;
  }

  MergeMediaEntitiesService get duplicateDetectionService {
    if (_duplicateDetectionService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _duplicateDetectionService!;
  }

  AlbumRelationshipService get albumRelationshipService {
    if (_albumRelationshipService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _albumRelationshipService!;
  }

  bool get isInitialized => _isInitialized;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Initialize all services and attempt to discover ExifTool.
  Future<void> initialize({final LoggingService? loggingService}) async {
    // If already initialized and no new logger provided, no-op.
    if (_isInitialized && loggingService == null) return;

    // If re-initializing with a new logger, clean up first.
    if (_isInitialized && loggingService != null) {
      await dispose();
    }

    _isInitialized = true;

    // Core services
    _globalConfig = GlobalConfigService();
    _loggingService =
        loggingService ??
        LoggingService(saveLog: ServiceContainer.instance.globalConfig.saveLog);
    _utilityService = const FormattingService();
    _diskSpaceService = ConsolidatedDiskSpaceService();

    // Media services
    final mediaHashService = MediaHashService()..logger = _loggingService!;
    _duplicateDetectionService = MergeMediaEntitiesService(
      hashService: mediaHashService,
    )..logger = _loggingService!;
    _albumRelationshipService = AlbumRelationshipService()
      ..logger = _loggingService!;

    // Interactive service
    _interactiveService = ConsolidatedInteractiveService(
      globalConfig: _globalConfig!,
    )..logger = _loggingService!;

    // ── ExifTool discovery (named arg as required by current API) ────────────
    final isReinitialization = loggingService != null;
    exifTool = await ExifToolService.find(
      showDiscoveryMessage: !isReinitialization,
    );

    if (exifTool != null) {
      // Wire logger for richer diagnostics
      exifTool!.logger = _loggingService!;

      // Optional: start persistent process for better throughput in bulk ops.
      // Your exiftool_service implements both one-shot and persistent paths.
      try {
        await exifTool!.startPersistentProcess();
      } catch (e) {
        // If persistent start fails, we still can use one-shot; log and continue.
        _loggingService!.warning('Failed to start persistent ExifTool: $e');
      }

      _globalConfig!.exifToolInstalled = true;
      _loggingService!.info('ExifTool initialized.');
    } else {
      _globalConfig!.exifToolInstalled = false;
      _loggingService!.warning(
        'Exiftool not found! Continuing without EXIF support...',
      );
    }
  }

  /// Dispose services and release resources.
  Future<void> dispose() async {
    // Dispose exiftool first to close processes/streams.
    if (exifTool != null) {
      try {
        await exifTool!.dispose();
      } catch (_) {}
      exifTool = null;
    }

    _isInitialized = false;

    _globalConfig = null;
    _loggingService = null;
    _utilityService = null;
    _diskSpaceService = null;
    _interactiveService = null;
    _duplicateDetectionService = null;
    _albumRelationshipService = null;
  }

  /// Reset the container (useful for tests)
  static Future<void> reset() async {
    await _instance?.dispose();
    _instance = null;
  }
}
