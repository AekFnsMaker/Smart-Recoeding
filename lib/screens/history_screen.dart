import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/speaker_tag.dart';
import '../services/audio_service.dart';

class HistoryScreen extends StatefulWidget {
  final AudioService audioService;

  const HistoryScreen({super.key, required this.audioService});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<RecordingSession> _sessions = [];
  bool _isLoading = true;
  RecordingSession? _selectedSession;

  static const List<Color> _speakerColors = [
    Color(0xFF2563EB),
    Color(0xFF7C3AED),
    Color(0xFF059669),
    Color(0xFFD97706),
    Color(0xFFDC2626),
    Color(0xFF0891B2),
    Color(0xFFDB2777),
    Color(0xFF4F46E5),
  ];

  Color _getSpeakerColor(String name) {
    final hash = name.codeUnits.fold(0, (prev, elem) => prev + elem);
    return _speakerColors[hash % _speakerColors.length];
  }

  @override
  void initState() {
    super.initState();
    widget.audioService.addListener(_onServiceUpdate);
    _loadSessions();
  }

  @override
  void dispose() {
    widget.audioService.removeListener(_onServiceUpdate);
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSessions() async {
    setState(() => _isLoading = true);
    final sessions = await widget.audioService.loadAllSessions();
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _isLoading = false;
        // If selected session was deleted, clear it
        if (_selectedSession != null &&
            !_sessions.any((s) => s.id == _selectedSession!.id)) {
          _selectedSession = null;
        }
      });
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _handleDeleteSession(RecordingSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Recording?'),
        content: Text(
            'This will permanently delete "${session.title}" and its exported JSON/CSV tag logs.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.audioService.deleteSession(session);
      await _loadSessions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording deleted.')),
        );
      }
    }
  }

  void _shareSessionFiles(RecordingSession session) async {
    final filesToShare = <XFile>[];

    if (File(session.audioPath).existsSync()) {
      filesToShare.add(XFile(session.audioPath, mimeType: 'audio/mp4'));
    }
    if (File(session.jsonPath).existsSync()) {
      filesToShare.add(XFile(session.jsonPath, mimeType: 'application/json'));
    }
    if (File(session.csvPath).existsSync()) {
      filesToShare.add(XFile(session.csvPath, mimeType: 'text/csv'));
    }

    if (filesToShare.isNotEmpty) {
      await Share.shareXFiles(
        filesToShare,
        text: 'SpeakerTagRecorder export: ${session.title}',
        subject: session.title,
      );
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Files not found on device.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Recording History',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadSessions,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.mic_off_rounded,
                        size: 64,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No recordings yet',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Recorded meetings and speaker tags will show here.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Top list of sessions
                    Expanded(
                      flex: _selectedSession != null ? 3 : 5,
                      child: ListView.separated(
                        itemCount: _sessions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final session = _sessions[index];
                          final isSelected =
                              _selectedSession?.id == session.id;

                          return ListTile(
                            selected: isSelected,
                            selectedTileColor:
                                theme.colorScheme.primaryContainer.withOpacity(0.25),
                            leading: CircleAvatar(
                              backgroundColor: isSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.secondaryContainer,
                              foregroundColor: isSelected
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSecondaryContainer,
                              child: const Icon(Icons.audiotrack_rounded),
                            ),
                            title: Text(
                              session.title,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              '${DateFormat('MMM dd, yyyy • HH:mm').format(session.startTime)} | '
                              '${session.formattedDuration} | ${session.tags.length} tags',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.share_rounded, size: 20),
                                  tooltip: 'Export & Share (JSON/CSV/Audio)',
                                  onPressed: () => _shareSessionFiles(session),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded,
                                      size: 20, color: Colors.redAccent),
                                  tooltip: 'Delete',
                                  onPressed: () =>
                                      _handleDeleteSession(session),
                                ),
                              ],
                            ),
                            onTap: () {
                              setState(() {
                                _selectedSession = session;
                              });
                              // Auto play when selected
                              widget.audioService.playSession(session);
                            },
                          );
                        },
                      ),
                    ),

                    // Playback & Tag Seek Panel (shown when a session is selected)
                    if (_selectedSession != null) ...[
                      const Divider(thickness: 2, height: 2),
                      Expanded(
                        flex: 4,
                        child: _buildPlaybackPanel(_selectedSession!, theme),
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _buildPlaybackPanel(RecordingSession session, ThemeData theme) {
    final isPlaying =
        widget.audioService.playerState == PlayerState.playing &&
            widget.audioService.currentlyPlayingPath == session.audioPath;

    final position = widget.audioService.playbackPosition;
    final maxDuration = session.duration > Duration.zero
        ? session.duration
        : widget.audioService.playbackDuration;

    // Detect active speaker at current playback position
    final activeTag = widget.audioService.getActiveSpeakerAt(
      position,
      session.tags,
    );

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Audio Player Controls Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
            child: Column(
              children: [
                // Session title and active speaker indicator
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        session.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (activeTag != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _getSpeakerColor(activeTag.speakerName)
                              .withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _getSpeakerColor(activeTag.speakerName),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.volume_up_rounded,
                              size: 14,
                              color: _getSpeakerColor(activeTag.speakerName),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              activeTag.speakerName,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: _getSpeakerColor(activeTag.speakerName),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                // Slider
                Slider(
                  value: position.inMilliseconds
                      .clamp(0, maxDuration.inMilliseconds)
                      .toDouble(),
                  max: maxDuration.inMilliseconds > 0
                      ? maxDuration.inMilliseconds.toDouble()
                      : 1.0,
                  onChanged: (val) {
                    widget.audioService
                        .seekPlayback(Duration(milliseconds: val.toInt()));
                  },
                ),
                // Time stamps & Playback button
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.replay_10_rounded),
                          tooltip: 'Rewind 10s',
                          onPressed: () {
                            final target =
                                position - const Duration(seconds: 10);
                            widget.audioService.seekPlayback(
                              target < Duration.zero ? Duration.zero : target,
                            );
                          },
                        ),
                        IconButton.filled(
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          onPressed: () {
                            if (isPlaying) {
                              widget.audioService.pausePlayback();
                            } else {
                              widget.audioService.playSession(session);
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.forward_10_rounded),
                          tooltip: 'Forward 10s',
                          onPressed: () {
                            final target =
                                position + const Duration(seconds: 10);
                            widget.audioService.seekPlayback(
                              target > maxDuration ? maxDuration : target,
                            );
                          },
                        ),
                      ],
                    ),
                    Text(
                      _formatDuration(maxDuration),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Speaker Tags Heading
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Speaker Tags (Tap to Seek)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Text(
                  '${session.tags.length} tags',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),

          // Interactive Speaker Tag List (Tap to Seek)
          Expanded(
            child: session.tags.isEmpty
                ? const Center(
                    child: Text(
                      'No speaker tags logged during this recording.',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    itemCount: session.tags.length,
                    itemBuilder: (context, index) {
                      final tag = session.tags[index];
                      final isCurrentTag = activeTag == tag;
                      final color = _getSpeakerColor(tag.speakerName);

                      return Material(
                        color: isCurrentTag
                            ? color.withOpacity(0.12)
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            // IMMEDIATELY SEEK TO EXACT TIMESTAMP
                            widget.audioService.seekPlayback(
                              Duration(milliseconds: tag.timestampMilliseconds),
                            );
                            if (!isPlaying) {
                              widget.audioService.playSession(session);
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                              vertical: 8.0,
                            ),
                            child: Row(
                              children: [
                                // Time seek pill
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isCurrentTag
                                        ? color
                                        : theme.colorScheme.surfaceVariant,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    tag.formattedTime,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: isCurrentTag
                                          ? Colors.white
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Speaker avatar & name
                                CircleAvatar(
                                  radius: 12,
                                  backgroundColor: color,
                                  child: Text(
                                    tag.speakerName.isNotEmpty
                                        ? tag.speakerName[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    tag.speakerName,
                                    style: TextStyle(
                                      fontWeight: isCurrentTag
                                          ? FontWeight.bold
                                          : FontWeight.w600,
                                      fontSize: 14,
                                      color: isCurrentTag
                                          ? color
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                                if (isCurrentTag)
                                  Icon(
                                    Icons.play_circle_filled_rounded,
                                    color: color,
                                    size: 18,
                                  )
                                else
                                  const Icon(
                                    Icons.touch_app_outlined,
                                    color: Colors.grey,
                                    size: 16,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
