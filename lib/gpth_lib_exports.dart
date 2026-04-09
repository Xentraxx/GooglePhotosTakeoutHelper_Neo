/// Public barrel of the library.
/// Import this from apps/bin/tests: `import 'package:<your_package_name>/gpth_lib_exports.dart';`
library;

/*
========================================================
Barrel for all common, reusable components across steps.
========================================================
*/

// modules from common/constants
export 'common/constants/constants.dart';
export 'common/constants/exif_constants.dart';
export 'common/constants/extra_formats.dart';
// modules from common/models
export 'common/models/io_paths_model.dart';
export 'common/models/processing_config_model.dart';
export 'common/models/processing_result_model.dart';
// modules from common/services/core_services
export 'common/services/core_services/container_service.dart';
export 'common/services/core_services/formatting_service.dart';
export 'common/services/core_services/global_config_service.dart';
export 'common/services/core_services/global_pools.dart';
export 'common/services/core_services/logging_service.dart';
export 'common/services/core_services/processing_metrics_service.dart';
export 'common/services/core_services/progress_saver_service.dart';
// modules from common/services/file_operations_services
export 'common/services/file_operations_services/file_extensions_service.dart';
export 'common/services/file_operations_services/file_system_service.dart';
export 'common/services/file_operations_services/filename_sanitizer_service.dart';
export 'common/services/file_operations_services/input_clone_service.dart';
export 'common/services/file_operations_services/path_resolver_service.dart';
export 'common/services/file_operations_services/zip_extraction_service.dart';
// modules from common/services/infrastructure
export 'common/services/infrastructure_services/concurrency_manager.dart';
export 'common/services/infrastructure_services/consolidated_disk_space_service.dart';
export 'common/services/infrastructure_services/exiftool_service.dart';
export 'common/services/infrastructure_services/platform_service.dart';
export 'common/services/infrastructure_services/windows_symlink_service.dart';
// modules from common/services/interactive_mode_services
export 'common/services/interactive_mode_services/consolidated_interactive_service.dart';
export 'common/services/interactive_mode_services/interactive_configuration_service.dart';
export 'common/services/interactive_mode_services/interactive_presenter_service.dart';
// modules from common/services/json_metadata_services
export 'common/services/json_metadata_services/json_metadata_matcher_service.dart';
// modules from common/services/media_services
export 'common/services/media_services/album_relationship_service.dart';
export 'common/services/media_services/content_grouping_service.dart';
export 'common/services/media_services/date_time_extraction_method.dart';
export 'common/services/media_services/edited_version_detector_service.dart';
export 'common/services/media_services/media_hash_service.dart';
export 'common/services/media_services/mime_type_service.dart';
// modules from common/value_objects
export 'common/value_objects/album_entity.dart';
export 'common/value_objects/date_accuracy.dart';
export 'common/value_objects/file_entity.dart';
export 'common/value_objects/media_entity.dart';
export 'common/value_objects/media_entity_collection.dart';
/*
============================================================
Barrel that exposes the pipeline and each step orchestration.
============================================================
*/

export 'steps/main_pipeline.dart';
// Step 01
export 'steps/step_01_fix_extensions/services/step_01_fix_extension_service.dart';
export 'steps/step_01_fix_extensions/step_01_fix_extensions.dart';
// Step 02
export 'steps/step_02_discover_media/services/step_02_discover_media_service.dart';
export 'steps/step_02_discover_media/services/takeout_folder_classifier_service.dart';
export 'steps/step_02_discover_media/step_02_discover_media.dart';
// Step 03
export 'steps/step_03_merge_media_entities/services/step_03_merge_media_entities_service.dart';
export 'steps/step_03_merge_media_entities/step_03_merge_media_entities.dart';
// Step 04
export 'steps/step_04_extract_dates/date_extractors/date_extractor_wrapper.dart';
export 'steps/step_04_extract_dates/date_extractors/exif_date_extractor.dart';
export 'steps/step_04_extract_dates/date_extractors/filename_date_extractor.dart';
export 'steps/step_04_extract_dates/date_extractors/folder_year_extractor.dart';
export 'steps/step_04_extract_dates/date_extractors/json_date_extractor.dart';
export 'steps/step_04_extract_dates/services/step_04_extract_dates_service.dart';
export 'steps/step_04_extract_dates/services/truncated_filename_fixer_service.dart';
export 'steps/step_04_extract_dates/step_04_extract_dates.dart';
// Step 05
export 'steps/step_05_find_albums/services/step_05_find_albums_service.dart';
export 'steps/step_05_find_albums/step_05_find_albums.dart';
// Step 06
export 'steps/step_06_move_files/moving_strategies/moving_strategies.dart';
export 'steps/step_06_move_files/services/file_operation_service.dart';
export 'steps/step_06_move_files/services/moving_types.dart';
export 'steps/step_06_move_files/services/path_generator_service.dart';
export 'steps/step_06_move_files/services/step_06_move_media_entity_service.dart';
export 'steps/step_06_move_files/services/symlink_service.dart';
export 'steps/step_06_move_files/step_06_move_media_entities.dart';
// Step 07
export 'steps/step_07_write_exif/services/step_07_write_exif_service.dart';
export 'steps/step_07_write_exif/services/write_exif_auxiliary_service.dart';
export 'steps/step_07_write_exif/step_07_write_exif.dart';
// Step 08
export 'steps/step_08_update_creation_time/services/step_08_update_creation_time_service.dart';
export 'steps/step_08_update_creation_time/step_08_update_creation_time.dart';
export 'steps/steps_pipeline.dart';
