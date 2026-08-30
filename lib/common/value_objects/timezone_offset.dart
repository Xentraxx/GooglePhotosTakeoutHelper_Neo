/// Value object representing a UTC timezone offset (e.g. `+08:00`, `-05:30`).
///
/// Used by the `--local-timezone` flag (issue #145) to convert UTC photo dates
/// from Google Photos Takeout metadata into the user's local timezone so that
/// re-uploading to Google Photos reproduces the original timeline.
///
/// Google Photos ignores the EXIF `OffsetTime` tag and interprets the naive
/// `DateTimeOriginal` clock as local time. By writing the local clock (UTC
/// instant + offset) together with the correct `OffsetTime`, the re-uploaded
/// photos appear at the correct local time.
///
/// This object intentionally stores only a fixed UTC offset (not an IANA
/// timezone name), which is sufficient for photo capture timestamps and
/// avoids pulling in the `timezone` package + tz database.
class TimezoneOffset {
  /// Creates a timezone offset from a [Duration].
  ///
  /// The duration is clamped to whole minutes. Throws [ArgumentError] if the
  /// offset is outside the valid range -12:00..+14:00.
  TimezoneOffset(this.duration) {
    if (duration.inMinutes < -720 || duration.inMinutes > 840) {
      throw ArgumentError(
        'Timezone offset must be between -12:00 and +14:00, got $duration',
      );
    }
  }

  /// The offset as a [Duration] (e.g. 8 hours for `+08:00`).
  final Duration duration;

  /// A zero offset (equivalent to UTC, `+00:00`).
  static final TimezoneOffset utc = TimezoneOffset(Duration.zero);

  /// Whether this offset is UTC (zero duration).
  bool get isUtc => duration == Duration.zero;

  /// The EXIF-formatted offset string, always `±HH:MM` with a sign and
  /// zero-padded hours/minutes (e.g. `+08:00`, `-05:30`, `+00:00`).
  ///
  /// This is the value written to the EXIF `OffsetTime`, `OffsetTimeOriginal`
  /// and `OffsetTimeDigitized` tags, and appended to XMP datetime strings.
  String get exifString {
    final int totalMinutes = duration.inMinutes;
    final String sign = totalMinutes.isNegative ? '-' : '+';
    final int absMinutes = totalMinutes.abs();
    final int hours = absMinutes ~/ 60;
    final int minutes = absMinutes % 60;
    return '$sign${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  }

  /// Parses a timezone offset string into a [TimezoneOffset].
  ///
  /// Accepted formats (case-insensitive, whitespace trimmed):
  /// - `+08:00`, `-05:30` — sign + `HH:MM`
  /// - `+08`, `-5`, `8`  — sign + hours (optionally without sign; no sign = positive)
  /// - `+0530`, `-530`   — sign + `HHMM` (no colon)
  /// - `Z` / `UTC`       — zero offset
  ///
  /// Throws [FormatException] if the input cannot be parsed or is outside
  /// the valid range -12:00..+14:00.
  static TimezoneOffset parse(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Timezone offset cannot be empty');
    }

    // Special-case UTC aliases.
    final String upper = trimmed.toUpperCase();
    if (upper == 'Z' || upper == 'UTC' || upper == '+00:00' || upper == '0') {
      return utc;
    }

    // Determine sign.
    bool negative = false;
    String body = trimmed;
    if (body.startsWith('+')) {
      body = body.substring(1);
    } else if (body.startsWith('-')) {
      negative = true;
      body = body.substring(1);
    }
    body = body.trim();
    if (body.isEmpty) {
      throw FormatException('Invalid timezone offset: "$input"');
    }
    // The body (after stripping the sign) must not itself start with a sign.
    if (body.startsWith('+') || body.startsWith('-')) {
      throw FormatException('Invalid timezone offset: "$input"');
    }

    final int? totalMinutes = _parseBody(body);
    if (totalMinutes == null) {
      throw FormatException('Invalid timezone offset: "$input"');
    }

    final int signedMinutes = negative ? -totalMinutes : totalMinutes;
    if (signedMinutes < -720 || signedMinutes > 840) {
      throw FormatException(
        'Timezone offset "$input" is out of range (must be between -12:00 and +14:00)',
      );
    }

    return TimezoneOffset(Duration(minutes: signedMinutes));
  }

  /// Parses [input] like [parse] but returns `null` on failure instead of
  /// throwing. Convenient for validation loops in interactive mode.
  static TimezoneOffset? tryParse(final String input) {
    try {
      return parse(input);
    } on FormatException {
      return null;
    }
  }

  /// Parses the body (without sign) into total minutes, or `null` on failure.
  static int? _parseBody(final String body) {
    // `HH:MM` form.
    if (body.contains(':')) {
      final parts = body.split(':');
      if (parts.length != 2) return null;
      final int? hours = int.tryParse(parts[0]);
      final int? minutes = int.tryParse(parts[1]);
      if (hours == null || minutes == null) return null;
      if (minutes < 0 || minutes > 59) return null;
      if (hours < 0 || hours > 14) return null;
      return hours * 60 + minutes;
    }

    // Pure digits: either `HHMM` (4 digits) or `H`/`HH` (hours only).
    if (int.tryParse(body) != null) {
      final int value = int.parse(body);
      if (body.length >= 3 && body.length <= 4) {
        // Treat as HHMM.
        final int hours = value ~/ 100;
        final int minutes = value % 100;
        if (minutes > 59) return null;
        if (hours > 14) return null;
        return hours * 60 + minutes;
      }
      // Hours only.
      if (value < 0 || value > 14) return null;
      return value * 60;
    }

    return null;
  }

  @override
  bool operator ==(final Object other) =>
      other is TimezoneOffset && other.duration == duration;

  @override
  int get hashCode => duration.hashCode;

  @override
  String toString() => exifString;
}
