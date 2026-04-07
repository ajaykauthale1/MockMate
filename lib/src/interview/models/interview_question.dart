import 'dart:convert';

enum Difficulty { easy, medium, hard }

class QuestionExample {
  final String input;
  final String output;
  final String? explanation;

  const QuestionExample({
    required this.input,
    required this.output,
    this.explanation,
  });

  factory QuestionExample.fromJson(Map<String, dynamic> json) =>
      QuestionExample(
        input: json['input'] as String,
        output: json['output'] as String,
        explanation: json['explanation'] as String?,
      );
}

class TestCase {
  final String label;
  final String stdin;
  final String expectedStdout;

  const TestCase({
    required this.label,
    required this.stdin,
    required this.expectedStdout,
  });

  factory TestCase.fromJson(Map<String, dynamic> json) => TestCase(
        label: json['label'] as String,
        stdin: json['stdin'] as String,
        expectedStdout: json['expected_stdout'] as String,
      );
}

class InterviewQuestion {
  final String id;
  final String title;
  final Difficulty difficulty;
  final List<String> tags;
  final String description;
  final List<QuestionExample> examples;
  final List<String> constraints;
  final Map<String, String> starterCode;
  final List<TestCase> hiddenTests;
  final String solutionNotes;

  const InterviewQuestion({
    required this.id,
    required this.title,
    required this.difficulty,
    required this.tags,
    required this.description,
    required this.examples,
    required this.constraints,
    required this.starterCode,
    required this.hiddenTests,
    required this.solutionNotes,
  });

  factory InterviewQuestion.fromJson(Map<String, dynamic> json) {
    final diffStr = json['difficulty'] as String;
    final difficulty = Difficulty.values.firstWhere(
      (d) => d.name == diffStr,
      orElse: () => Difficulty.medium,
    );

    return InterviewQuestion(
      id: json['id'] as String,
      title: json['title'] as String,
      difficulty: difficulty,
      tags: List<String>.from(json['tags'] as List),
      description: json['description'] as String,
      examples: (json['examples'] as List)
          .map((e) => QuestionExample.fromJson(e as Map<String, dynamic>))
          .toList(),
      constraints: List<String>.from(json['constraints'] as List),
      starterCode: Map<String, String>.from(json['starter_code'] as Map),
      hiddenTests: (json['hidden_tests'] as List)
          .map((t) => TestCase.fromJson(t as Map<String, dynamic>))
          .toList(),
      solutionNotes: json['solution_notes'] as String,
    );
  }

  factory InterviewQuestion.fromJsonString(String raw) =>
      InterviewQuestion.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  String? starterCodeFor(String language) => starterCode[language];
}
