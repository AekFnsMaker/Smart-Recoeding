import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/speaker_tag.dart';

enum RecordingStatus { idle, recording, paused }

class AudioService extends ChangeNotifier {
  // --- Recording ---
  final AudioRecorder _audioRecorder = AudioRecorder();
  RecordingStatus _recordingStatus = RecordingStatus.idle;
  RecordingStatus get recordingStatus => _recordingStatus;

  Timer? _ticker;
  int _elapsedMilliseconds = 0;
  int get elapsedMilliseconds => _elapsedMilliseconds;

  String? _currentAudioPath;
  String? _currentSessionId;
  DateTime? _sessionStartTime;
  String? _activeSpeaker;
  String? get activeSpeaker => _activeSpeaker;

  final List<SpeakerTag> _activeTags = [];
  List<SpeakerTag> get activeTags => List.unmodifiable(_activeTags);

  // --- Playback ---
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  PlayerState get playerState => _playerState;

  Duration _playbackPosition = Duration.zero;
  Duration get playbackPosition => _playbackPosition;

  Duration _playbackDuration = Duration.zero;
  Duration get playbackDuration => _playbackDuration;

  String? _currentlyPlayingPath;
  String? get currentlyPlayingPath => _currentlyPlayingPath;

  // Stream subscriptions
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  AudioService() {
    _initPlayerListeners();
  }

  void _initPlayerListeners() {
    _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((state) {
      _playerState = state;
      notifyListeners();
    });

    _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
      _playbackPosition = pos;
      notifyListeners();
    });

    _durationSub = _audioPlayer.onDurationChanged.listen((dur) {
      _playbackDuration = dur;
      notifyListeners();
    });
  }

  // ==========================================
  // RECORDING METHODS
  // ==========================================

  /// Checks and requests necessary audio recording permissions.
  Future<bool> checkAndRequestPermissions() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      return false;
    }
    return true;
  }

  /// Starts a new recording session.
  Future<bool> startRecording({String? sessionTitle}) async {
    final hasPermission = await checkAndRequestPermissions();
    if (!hasPermission) return false;

    // Reset recording session state
    final appDir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final timestampStr = DateFormat('yyyyMMdd_HHmmss').format(now);
    _currentSessionId = 'session_$timestampStr';
    _sessionStartTime = now;
    _elapsedMilliseconds = 0;
    _activeTags.clear();
    _activeSpeaker = null;

    final sessionDir = Directory(p.join(appDir.path, 'recordings'));
    if (!await sessionDir.exists()) {
      await sessionDir.create(recursive: true);
    }

    _currentAudioPath = p.join(sessionDir.path, '$_currentSessionId.m4a');

    // Configure encoder for standard AAC in M4A container (clean, high compatibility)
    const config = RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 128000,
      sampleRate: 44100,
    );

    await _audioRecorder.start(config, path: _currentAudioPath!);

    _recordingStatus = RecordingStatus.recording;
    _startTimer();
    notifyListeners();
    return true;
  }

  /// Pauses active recording.
  Future<void> pauseRecording() async {
    if (_recordingStatus != RecordingStatus.recording) return;
    await _audioRecorder.pause();
    _ticker?.cancel();
    _recordingStatus = RecordingStatus.paused;
    notifyListeners();
  }

  /// Resumes recording from paused state.
  Future<void> resumeRecording() async {
    if (_recordingStatus != RecordingStatus.paused) return;
    await _audioRecorder.resume();
    _recordingStatus = RecordingStatus.recording;
    _startTimer();
    notifyListeners();
  }

  /// Tags the speaker in real time without interrupting recording.
  void tagSpeaker(String speakerName) {
    if (_recordingStatus == RecordingStatus.idle) return;

    _activeSpeaker = speakerName;
    final tag = SpeakerTag(
      speakerName: speakerName,
      timestampMilliseconds: _elapsedMilliseconds,
      createdAt: DateTime.now(),
    );
    _activeTags.add(tag);
    notifyListeners();
  }

  /// Stops recording and saves metadata JSON and CSV files alongside audio.
  Future<RecordingSession?> stopRecording({String? sessionTitle}) async {
    if (_recordingStatus == RecordingStatus.idle) return null;

    _ticker?.cancel();
    final finalAudioPath = await _audioRecorder.stop() ?? _currentAudioPath;
    final totalDuration = Duration(milliseconds: _elapsedMilliseconds);

    final appDir = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(p.join(appDir.path, 'recordings'));
    final jsonPath = p.join(sessionDir.path, '$_currentSessionId.json');
    final csvPath = p.join(sessionDir.path, '$_currentSessionId.csv');

    final title = sessionTitle?.trim().isNotEmpty == true
        ? sessionTitle!.trim()
        : 'Meeting ${DateFormat('MMM dd, yyyy HH:mm').format(_sessionStartTime ?? DateTime.now())}';

    final session = RecordingSession(
      id: _currentSessionId!,
      title: title,
      audioPath: finalAudioPath!,
      jsonPath: jsonPath,
      csvPath: csvPath,
      startTime: _sessionStartTime ?? DateTime.now(),
      duration: totalDuration,
      tags: List.from(_activeTags),
    );

    // Save JSON metadata
    final jsonFile = File(jsonPath);
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );

    // Save CSV metadata
    final csvFile = File(csvPath);
    await csvFile.writeAsString(session.toCsv());

    _recordingStatus = RecordingStatus.idle;
    _activeSpeaker = null;
    _elapsedMilliseconds = 0;
    notifyListeners();

    return session;
  }

  void _startTimer() {
    _ticker?.cancel();
    // 100ms interval for smooth UI and accurate millisecond tracking
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _elapsedMilliseconds += 100;
      notifyListeners();
    });
  }

  // ==========================================
  // PLAYBACK METHODS
  // ==========================================

  Future<void> playSession(RecordingSession session) async {
    try {
      if (_currentlyPlayingPath == session.audioPath &&
          _playerState == PlayerState.paused) {
        await _audioPlayer.resume();
      } else {
        await _audioPlayer.stop();
        _currentlyPlayingPath = session.audioPath;
        _playbackDuration = session.duration;
        await _audioPlayer.play(DeviceFileSource(session.audioPath));
      }
    } catch (e) {
      debugPrint('Error playing audio: $e');
    }
  }

  Future<void> pausePlayback() async {
    await _audioPlayer.pause();
  }

  Future<void> resumePlayback() async {
    await _audioPlayer.resume();
  }

  Future<void> stopPlayback() async {
    await _audioPlayer.stop();
    _playbackPosition = Duration.zero;
    _currentlyPlayingPath = null;
    notifyListeners();
  }

  Future<void> seekPlayback(Duration targetPosition) async {
    await _audioPlayer.seek(targetPosition);
  }

  /// Determines the active speaker at the given playback position.
  SpeakerTag? getActiveSpeakerAt(Duration position, List<SpeakerTag> tags) {
    if (tags.isEmpty) return null;
    final currentMs = position.inMilliseconds;
    SpeakerTag? active;
    for (final tag in tags) {
      if (tag.timestampMilliseconds <= currentMs) {
        active = tag;
      } else {
        break;
      }
    }
    return active;
  }

  // ==========================================
  // STORAGE & SESSION MANAGEMENT
  // ==========================================

  /// Loads all saved recording sessions from device storage.
  Future<List<RecordingSession>> loadAllSessions() async {
    final appDir = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(p.join(appDir.path, 'recordings'));
    if (!await sessionDir.exists()) {
      return [];
    }

    final List<RecordingSession> sessions = [];
    final files = sessionDir.listSync();

    for (final file in files) {
      if (file is File && file.path.endsWith('.json')) {
        try {
          final content = await file.readAsString();
          final map = jsonDecode(content) as Map<String, dynamic>;
          final session = RecordingSession.fromJson(map);
          // Confirm that audio file also exists
          if (File(session.audioPath).existsSync()) {
            sessions.add(session);
          }
        } catch (e) {
          debugPrint('Failed to parse session file ${file.path}: $e');
        }
      }
    }

    // Sort by most recent start time
    sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
    return sessions;
  }

  /// Deletes audio and metadata files for a session.
  Future<void> deleteSession(RecordingSession session) async {
    if (_currentlyPlayingPath == session.audioPath) {
      await stopPlayback();
    }

    final audioFile = File(session.audioPath);
    if (await audioFile.exists()) {
      await audioFile.delete();
    }

    final jsonFile = File(session.jsonPath);
    if (await jsonFile.exists()) {
      await jsonFile.delete();
    }

    final csvFile = File(session.csvPath);
    if (await csvFile.exists()) {
      await csvFile.delete();
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
}
