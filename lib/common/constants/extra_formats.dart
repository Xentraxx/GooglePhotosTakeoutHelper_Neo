/// Constants for identifying and handling "extra" format patterns
///
/// This file contains language-specific suffixes used to identify edited
/// versions of photos and videos that should be filtered out during processing.
library;

/// List of language-specific "edited" format suffixes
///
/// These patterns are used to identify files that are edited versions
/// of original photos/videos and should typically be excluded from processing.
/// All patterns should be lowercase for case-insensitive matching.
const List<String> extraFormats = <String>[
  // Special Suffixes (are always in English)
  '-effects',
  '-motion',
  '-animation',
  '-smile',
  '-collage',
  '-mix',

  // Edited Suffixes (language-specific)
  '-edited', // EN/US - thanks @DalenW
  '-edytowane', // PL
  '-bearbeitet', // DE - thanks @cintx
  '-bewerkt', // NL - thanks @jaapp
  '-編集済み', // JA - thanks @fossamagna
  '-编辑', // ZH - Chinese
  '-modificato', // IT - thanks @rgstori
  '-modifié', // FR - for @palijn's problems <3
  '-ha editado', // ES - @Sappstal report
  '-editada', // ES - As seen in issue 105
  '-editado', // IT
  '-editat', // CA - @Sappstal report
  // Add more "edited" flags in more languages if you want.
  // They need to be lowercase.
];
