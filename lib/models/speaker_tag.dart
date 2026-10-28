import 'dart:convert';

/// Represents a single speaker attribution logged at a specific audio timestamp.
class SpeakerTag {
  final String speakerName;
  final int timestampMilliseconds;
  final DateTime createdAt;

  SpeakerTag({
    required this.speakerName,
    required this.timestampMilliseconds,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  double get timestampSeconds => timestampMilliseconds / 1000.0;

  String get formattedTime {
    final totalSeconds = (timestampMilliseconds / 1000).floor();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  Map<String, dynamic> toJson() => {
        'speaker_name': speakerName,
        'timestamp_ms': timestampMilliseconds,
        'timestamp_seconds': double.parse((timestampMilliseconds / 1000.0).toStringAsFixed(2)),
        'formatted_time': formattedTime,
        'created_at': createdAt.toIso8601String(),
      };

  factory SpeakerTag.fromJson(Map<String, dynamic> json) {
    int ms = 0;
    if (json['timestamp_ms'] != null) {
      ms = (json['timestamp_ms'] as num).toInt();
    } else if (json['timestamp_seconds'] != null) {
      ms = ((json['timestamp_seconds'] as num).toDouble() * 1000).round();
    }

    return SpeakerTag(
      speakerName: json['speaker_name'] as String? ?? 'Unknown',
      timestampMilliseconds: ms,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// Represents a complete recorded meeting session with audio file path and speaker tags.
class RecordingSession {
  final String id;
  final String title;
  final String audioPath;
  final String jsonPath;
  final String csvPath;
  final DateTime startTime;
  final Duration duration;
  final List<SpeakerTag> tags;

  RecordingSession({
    required this.id,
    required this.title,
    required this.audioPath,
    required this.jsonPath,
    required this.csvPath,
    required this.startTime,
    required this.duration,
    required this.tags,
  });

  String get formattedDuration {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Calculates total unique speakers in this session
  Set<String> get uniqueSpeakers => tags.map((t) => t.speakerName).toSet();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'audio_path': audioPath,
        'json_path': jsonPath,
        'csv_path': csvPath,
        'start_time': startTime.toIso8601String(),
        'duration_ms': duration.inMilliseconds,
        'duration_seconds': (duration.inMilliseconds / 1000.0),
        'duration_formatted': formattedDuration,
        'total_tags': tags.length,
        'tags': tags.map((t) => t.toJson()).toList(),
      };

  factory RecordingSession.fromJson(Map<String, dynamic> json) {
    return RecordingSession(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title'] as String? ?? 'Meeting Recording',
      audioPath: json['audio_path'] as String? ?? '',
      jsonPath: json['json_path'] as String? ?? '',
      csvPath: json['csv_path'] as String? ?? '',
      startTime: json['start_time'] != null
          ? DateTime.tryParse(json['start_time'] as String) ?? DateTime.now()
          : DateTime.now(),
      duration: Duration(milliseconds: json['duration_ms'] as int? ?? 0),
      tags: (json['tags'] as List<dynamic>?)
              ?.map((e) => SpeakerTag.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// Formats the session and speaker tags into standard CSV format.
  String toCsv() {
    final buffer = StringBuffer();
    // Header summary
    buffer.writeln('# SpeakerTagRecorder Session Export');
    buffer.writeln('session_id,title,start_time,duration_seconds,formatted_duration,total_tags');
    buffer.writeln(
        '"$id","$title","${startTime.toIso8601String()}",${(duration.inMilliseconds / 1000.0).toStringAsFixed(2)},"$formattedDuration",${tags.length}');
    buffer.writeln();
    // Tag list
    buffer.writeln('tag_index,timestamp_seconds,timestamp_formatted,speaker_name,recorded_at');
    for (int i = 0; i < tags.length; i++) {
      final tag = tags[i];
      buffer.writeln(
          '${i + 1},${tag.timestampSeconds.toStringAsFixed(2)},"${tag.formattedTime}","${tag.speakerName}","${tag.createdAt.toIso8601String()}"');
    }
    return buffer.toString();
  }
}
