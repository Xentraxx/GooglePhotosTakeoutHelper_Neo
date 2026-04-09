import 'dart:io';
import 'package:gpth_neo/gpth_lib_exports.dart';

/// Abstract base class for all GPTH processing steps
///
/// This replaces the numbered step comments with proper, testable step classes
/// that can be executed independently and provide consistent progress reporting.
abstract class ProcessingStep {
  const ProcessingStep(this.name);

  /// Human-readable name of this step
  final String name;

  /// Execute this processing step
  Future<StepResult> execute(final ProcessingContext context);

  /// Optional validation before step execution
  Future<void> validate(final ProcessingContext context) async {
    // Default implementation does nothing
  }

  /// Whether this step should be skipped based on context/configuration
  bool shouldSkip(final ProcessingContext context) => false;

  /// Checks if this step was previously completed and loads stored results if so.
  ///
  /// Returns a cached [StepResult] when the step is already done,
  /// or `null` when normal execution should proceed.
  Future<StepResult?> checkResume(
    final ProcessingContext context,
    final int stepId,
  ) async {
    if (context.config.disableResumeCheck) return null;
    try {
      final progress = await StepProgressLoader.readProgressJson(context);
      if (progress != null &&
          StepProgressLoader.isStepCompleted(
            progress,
            stepId,
            context: context,
          )) {
        final dur = StepProgressLoader.readDurationForStep(progress, stepId);
        final data = StepProgressLoader.readResultDataForStep(progress, stepId);
        final msg = StepProgressLoader.readMessageForStep(progress, stepId);
        StepProgressLoader.updateMediaEntityCollection(
          context,
          progress['media_entity_collection_object'],
          progressJson: progress,
        );
        return StepResult.success(
          stepName: name,
          duration: dur,
          data: data,
          message: msg.isEmpty
              ? 'Resume: loaded Step $stepId results from progress.json'
              : msg,
        );
      }
    } catch (_) {}
    return null;
  }
}

/// Result of executing a processing step
class StepResult {
  const StepResult({
    required this.stepName,
    required this.duration,
    required this.isSuccess,
    this.data = const {},
    this.message,
    this.error,
  });

  /// Create a successful result
  StepResult.success({
    required final String stepName,
    required final Duration duration,
    final Map<String, dynamic> data = const {},
    final String? message,
  }) : this(
         stepName: stepName,
         duration: duration,
         isSuccess: true,
         data: data,
         message: message,
       );

  /// Create a failed result
  StepResult.failure({
    required final String stepName,
    required final Duration duration,
    required final Exception error,
    final String? message,
  }) : this(
         stepName: stepName,
         duration: duration,
         isSuccess: false,
         error: error,
         message: message,
       );

  final String stepName;
  final Duration duration;
  final bool isSuccess;
  final Map<String, dynamic> data;
  final String? message;
  final Exception? error;

  /// Get a value from the step data
  T? getData<T>(final String key) => data[key] as T?;

  /// Get a value from the step data with a default
  T getDataOrDefault<T>(final String key, final T defaultValue) =>
      (data[key] as T?) ?? defaultValue;
}

/// Context object passed between processing steps
class ProcessingContext {
  ProcessingContext({
    required this.config,
    required this.mediaCollection,
    required this.inputDirectory,
    required this.outputDirectory,
    final Map<String, dynamic>? stepResults,
  }) : stepResults = stepResults ?? {};

  final ProcessingConfig config;
  final MediaEntityCollection mediaCollection;
  final Directory inputDirectory;
  final Directory outputDirectory;
  final Map<String, dynamic> stepResults;

  /// Year folders found during processing
  final List<Directory> yearFolders = [];

  /// Album folders found during processing
  final List<Directory> albumFolders = [];

  /// Store result data from a completed step
  void setStepResult(final String stepName, final Object? data) {
    stepResults[stepName] = data;
  }

  /// Get result data from a previous step
  T? getStepResult<T>(final String stepName) => stepResults[stepName] as T?;

  /// Get result data with a default value
  T getStepResultOrDefault<T>(final String stepName, final T defaultValue) =>
      (stepResults[stepName] as T?) ?? defaultValue;
}

/// Exception thrown during step execution
class StepExecutionException implements Exception {
  const StepExecutionException(this.stepName, this.message, [this.cause]);

  final String stepName;
  final String message;
  final Exception? cause;

  @override
  String toString() => 'StepExecutionException in $stepName: $message';
}
