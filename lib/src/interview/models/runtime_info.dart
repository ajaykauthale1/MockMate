enum SupportedLanguage { python, javascript, java, go, cpp }

extension SupportedLanguageExt on SupportedLanguage {
  String get displayName => switch (this) {
        SupportedLanguage.python => 'Python',
        SupportedLanguage.javascript => 'JavaScript',
        SupportedLanguage.java => 'Java',
        SupportedLanguage.go => 'Go',
        SupportedLanguage.cpp => 'C++',
      };

  String get jsonKey => switch (this) {
        SupportedLanguage.python => 'python',
        SupportedLanguage.javascript => 'javascript',
        SupportedLanguage.java => 'java',
        SupportedLanguage.go => 'go',
        SupportedLanguage.cpp => 'cpp',
      };

  String get fileExtension => switch (this) {
        SupportedLanguage.python => 'py',
        SupportedLanguage.javascript => 'js',
        SupportedLanguage.java => 'java',
        SupportedLanguage.go => 'go',
        SupportedLanguage.cpp => 'cpp',
      };
}

class RuntimeInfo {
  final SupportedLanguage language;
  final bool installed;
  final String? version;
  final String? executablePath;

  const RuntimeInfo({
    required this.language,
    required this.installed,
    this.version,
    this.executablePath,
  });

  String get statusLabel {
    if (!installed) return '${language.displayName} — Install';
    final v = version;
    return v != null ? '${language.displayName} $v' : language.displayName;
  }

  RuntimeInfo copyWith({
    bool? installed,
    String? version,
    String? executablePath,
  }) =>
      RuntimeInfo(
        language: language,
        installed: installed ?? this.installed,
        version: version ?? this.version,
        executablePath: executablePath ?? this.executablePath,
      );
}
