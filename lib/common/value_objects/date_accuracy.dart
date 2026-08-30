/// Value object representing the accuracy of a date extraction
///
/// Lower values indicate higher accuracy. This allows for proper
/// comparison when merging duplicate media with different date sources.
class DateAccuracy {
  /// Creates a date accuracy value
  const DateAccuracy(this.value);

  /// Creates a DateAccuracy from an integer value
  factory DateAccuracy.fromInt(final int? accuracyValue) {
    if (accuracyValue == null) return unknown;

    return switch (accuracyValue) {
      1 => perfect,
      2 => good,
      3 => fair,
      4 => poor,
      _ when accuracyValue >= 999 => unknown,
      _ => DateAccuracy(accuracyValue),
    };
  }

  /// Perfect accuracy - extracted from reliable metadata
  static const DateAccuracy perfect = DateAccuracy(1);

  /// Good accuracy - extracted from EXIF or JSON metadata
  static const DateAccuracy good = DateAccuracy(2);

  /// Fair accuracy - extracted from filename patterns
  static const DateAccuracy fair = DateAccuracy(3);

  /// Poor accuracy - guessed or estimated
  static const DateAccuracy poor = DateAccuracy(4);

  /// Unknown accuracy - no date information available
  static const DateAccuracy unknown = DateAccuracy(999);

  /// The numeric accuracy value (lower is better)
  final int value;

  /// Whether this accuracy is better than another
  bool isBetterThan(final DateAccuracy other) => value < other.value;

  /// Gets a human-readable description of the accuracy level
  String get description => switch (value) {
    1 => 'Perfect (from reliable metadata)',
    2 => 'Good (from EXIF/JSON)',
    3 => 'Fair (from filename)',
    4 => 'Poor (estimated)',
    >= 999 => 'Unknown (no date info)',
    _ => 'Custom (accuracy: $value)',
  };

  @override
  bool operator ==(final Object other) {
    if (identical(this, other)) return true;
    return other is DateAccuracy && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'DateAccuracy($value)';

  /// Comparison operator for sorting (better accuracy comes first)
  int compareTo(final DateAccuracy other) => value.compareTo(other.value);
}
