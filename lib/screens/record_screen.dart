import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/audio_service.dart';
import 'history_screen.dart';

class RecordScreen extends StatefulWidget {
  final AudioService audioService;

  const RecordScreen({super.key, required this.audioService});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  // Pre-configured speaker list
  final List<String> _speakers = ['Tee', 'Aek', 'Golf', 'Cat', 'Phiat', 'Sek'];
  final TextEditingController _newSpeakerController = TextEditingController();
  final TextEditingController _sessionTitleController = TextEditingController();
  final ScrollController _tagsScrollController = ScrollController();

  // Distinct color palette for speaker pills/buttons
  static const List<Color> _speakerColors = [
    Color(0xFF2563EB), // Blue
    Color(0xFF7C3AED), // Purple
    Color(0xFF059669), // Green
    Color(0xFFD97706), // Amber
    Color(0xFFDC2626), // Red
    Color(0xFF0891B2), // Cyan
    Color(0xFFDB2777), // Pink
    Color(0xFF4F46E5), // Indigo
  ];

  Color _getSpeakerColor(String name) {
    final hash = name.codeUnits.fold(0, (prev, elem) => prev + elem);
    return _speakerColors[hash % _speakerColors.length];
  }

  @override
  void initState() {
    super.initState();
    widget.audioService.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    widget.audioService.removeListener(_onServiceUpdate);
    _newSpeakerController.dispose();
    _sessionTitleController.dispose();
    _tagsScrollController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) {
      setState(() {});
      // Auto-scroll tags list to the latest tag
      if (widget.audioService.activeTags.isNotEmpty &&
          _tagsScrollController.hasClients) {
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_tagsScrollController.hasClients) {
            _tagsScrollController.animateTo(
              _tagsScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }
  }

  String _formatTimer(int milliseconds) {
    final totalSeconds = (milliseconds / 1000).floor();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final msDigit = ((milliseconds % 1000) / 100).floor();

    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.$msDigit';
  }

  void _showAddSpeakerDialog() {
    _newSpeakerController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Speaker'),
        content: TextField(
          controller: _newSpeakerController,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Speaker Name',
            hintText: 'e.g. Somchai, Sarah, Dr. John',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _confirmAddSpeaker(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _confirmAddSpeaker,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _confirmAddSpeaker() {
    final name = _newSpeakerController.text.trim();
    if (name.isNotEmpty && !_speakers.contains(name)) {
      setState(() {
        _speakers.add(name);
      });
      Navigator.pop(context);
    }
  }

  void _removeSpeaker(String speaker) {
    if (widget.audioService.recordingStatus == RecordingStatus.recording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot remove speakers while recording.')),
      );
      return;
    }
    setState(() {
      _speakers.remove(speaker);
    });
  }

  Future<void> _handleStartRecording() async {
    final now = DateTime.now();
    _sessionTitleController.text =
        'Meeting ${DateFormat('yyyy-MM-dd HH:mm').format(now)}';

    final success = await widget.audioService.startRecording(
      sessionTitle: _sessionTitleController.text,
    );

    if (!success && mounted) {
      final isPermDenied =
          await widget.audioService.isPermissionPermanentlyDenied();
      if (isPermDenied && mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Microphone Permission Required'),
            content: const Text(
                'Microphone permission is required to record meetings. Please enable it in Settings.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission required to start recording.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _handleStopRecording() async {
    final session = await widget.audioService.stopRecording(
      sessionTitle: _sessionTitleController.text,
    );

    if (session != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved "${session.title}" (${session.tags.length} speaker tags)'),
          backgroundColor: Colors.green,
          action: SnackBarAction(
            label: 'View History',
            textColor: Colors.white,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (ctx) => HistoryScreen(audioService: widget.audioService),
                ),
              );
            },
          ),
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording stopped. No session file was created.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.audioService.recordingStatus;
    final isRecording = status == RecordingStatus.recording;
    final isPaused = status == RecordingStatus.paused;
    final isIdle = status == RecordingStatus.idle;

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.mic,
                color: theme.colorScheme.onPrimaryContainer,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'SpeakerTagRecorder',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton.filledTonal(
            tooltip: 'Recording History',
            icon: const Icon(Icons.history_rounded),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (ctx) => HistoryScreen(audioService: widget.audioService),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Status and Real-time Timer Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: isRecording
                        ? Colors.redAccent.withOpacity(0.6)
                        : isPaused
                            ? Colors.amber.withOpacity(0.6)
                            : theme.colorScheme.outlineVariant,
                    width: isRecording || isPaused ? 2 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                  child: Column(
                    children: [
                      // Status badge
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isRecording
                                  ? Colors.red
                                  : isPaused
                                      ? Colors.amber
                                      : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            isRecording
                                ? 'RECORDING LIVE'
                                : isPaused
                                    ? 'RECORDING PAUSED'
                                    : 'STANDBY',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: isRecording
                                  ? Colors.red
                                  : isPaused
                                      ? Colors.amber.shade800
                                      : Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Time display
                      Text(
                        _formatTimer(widget.audioService.elapsedMilliseconds),
                        style: const TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w800,
                          fontFamily: 'monospace',
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (widget.audioService.activeSpeaker != null && !isIdle)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            color: _getSpeakerColor(
                                    widget.audioService.activeSpeaker!)
                                .withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _getSpeakerColor(
                                  widget.audioService.activeSpeaker!),
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.record_voice_over_rounded,
                                size: 16,
                                color: _getSpeakerColor(
                                    widget.audioService.activeSpeaker!),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Speaking: ${widget.audioService.activeSpeaker!}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _getSpeakerColor(
                                      widget.audioService.activeSpeaker!),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // Speaker Tagging Section Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Tap Speaker to Tag',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (!isIdle)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'Active',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: _showAddSpeakerDialog,
                    icon: const Icon(Icons.person_add_rounded, size: 18),
                    label: const Text('Add Speaker'),
                  ),
                ],
              ),
            ),

            // Large Speaker Buttons Grid
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 2.1,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _speakers.length,
                  itemBuilder: (context, index) {
                    final speaker = _speakers[index];
                    final isCurrentSpeaker =
                        widget.audioService.activeSpeaker == speaker && !isIdle;
                    final color = _getSpeakerColor(speaker);

                    return Material(
                      color: isCurrentSpeaker
                          ? color
                          : color.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                      elevation: isCurrentSpeaker ? 6 : 0,
                      shadowColor: color.withOpacity(0.5),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          if (isIdle) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Start recording first to tag speakers.'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                            return;
                          }
                          widget.audioService.tagSpeaker(speaker);
                        },
                        onLongPress: () {
                          // Allow deleting a speaker
                          showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text('Remove "$speaker"?'),
                              content: const Text(
                                  'Do you want to remove this speaker from the quick buttons?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Colors.red),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _removeSpeaker(speaker);
                                  },
                                  child: const Text('Remove'),
                                ),
                              ],
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isCurrentSpeaker
                                  ? Colors.white.withOpacity(0.9)
                                  : color.withOpacity(0.4),
                              width: isCurrentSpeaker ? 2.5 : 1.2,
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: isCurrentSpeaker
                                    ? Colors.white
                                    : color,
                                child: Text(
                                  speaker.isNotEmpty ? speaker[0].toUpperCase() : '?',
                                  style: TextStyle(
                                    color: isCurrentSpeaker
                                        ? color
                                        : Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      speaker,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: isCurrentSpeaker
                                            ? Colors.white
                                            : theme.colorScheme.onSurface,
                                      ),
                                    ),
                                    if (isCurrentSpeaker)
                                      const Row(
                                        children: [
                                          Icon(
                                            Icons.graphic_eq_rounded,
                                            size: 14,
                                            color: Colors.white70,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'Speaking now',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // Live Tags Timeline Stream (Real-Time Tags Log)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  const Icon(Icons.bookmarks_rounded, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(
                    'Live Tags (${widget.audioService.activeTags.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16.0),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: widget.audioService.activeTags.isEmpty
                    ? Center(
                        child: Text(
                          isIdle
                              ? 'Tap "Record" below to begin meeting'
                              : 'Tap any speaker button above to add a tag',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _tagsScrollController,
                        itemCount: widget.audioService.activeTags.length,
                        itemBuilder: (context, index) {
                          final tag = widget.audioService.activeTags[index];
                          final color = _getSpeakerColor(tag.speakerName);
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3.0),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: theme.colorScheme.outlineVariant),
                                  ),
                                  child: Text(
                                    tag.formattedTime,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                CircleAvatar(
                                  radius: 6,
                                  backgroundColor: color,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  tag.speakerName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: color,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),

            // Bottom Audio Controls Bar
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    offset: const Offset(0, -3),
                    blurRadius: 10,
                  )
                ],
              ),
              child: isIdle
                  ? SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: _handleStartRecording,
                        icon: const Icon(Icons.fiber_manual_record, size: 24),
                        label: const Text(
                          'START RECORDING',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    )
                  : Row(
                      children: [
                        // Pause / Resume Button
                        Expanded(
                          child: SizedBox(
                            height: 54,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () {
                                if (isRecording) {
                                  widget.audioService.pauseRecording();
                                } else {
                                  widget.audioService.resumeRecording();
                                }
                              },
                              icon: Icon(
                                isRecording
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                              label: Text(
                                isRecording ? 'PAUSE' : 'RESUME',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Stop & Save Button
                        Expanded(
                          flex: 2,
                          child: SizedBox(
                            height: 54,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red.shade700,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _handleStopRecording,
                              icon: const Icon(Icons.stop_rounded),
                              label: const Text(
                                'STOP & SAVE',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
