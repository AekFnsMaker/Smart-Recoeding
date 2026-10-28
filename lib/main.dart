import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Allow both Tablet Landscape & Portrait orientations
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Modern Dark/Slate transparent status bar
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0F172A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const QuickScratchpadApp());
}

/// Root Application Widget for Tablet-Optimized Quick Voice & Scratchpad Capture
class QuickScratchpadApp extends StatelessWidget {
  const QuickScratchpadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quick Voice & Scratchpad',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19), // Deep Slate
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6366F1), // Indigo
          secondary: const Color(0xFF38BDF8), // Sky Blue
          surface: const Color(0xFF1E293B), // Card Slate
          error: const Color(0xFFEF4444), // Danger Red
          onPrimary: Colors.white,
          onSurface: const Color(0xFFF1F5F9),
        ),
        fontFamily: 'sans-serif',
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF334155)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF334155)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
          ),
          hintStyle: const TextStyle(color: Color(0xFF64748B)),
        ),
      ),
      home: const ScratchpadCaptureScreen(),
    );
  }
}

/// Main Screen with Zero-Click Auto-Record, Tablet Scratchpad, and One-Click Dual Export
class ScratchpadCaptureScreen extends StatefulWidget {
  const ScratchpadCaptureScreen({super.key});

  @override
  State<ScratchpadCaptureScreen> createState() =>
      _ScratchpadCaptureScreenState();
}

class _ScratchpadCaptureScreenState extends State<ScratchpadCaptureScreen>
    with SingleTickerProviderStateMixin {
  // Controllers & Nodes
  final TextEditingController _projectController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final FocusNode _notesFocusNode = FocusNode();

  // Audio Recording Instance (record: ^5.x.x / ^6.x.x compatible)
  final AudioRecorder _audioRecorder = AudioRecorder();

  // State Variables
  bool _isRecording = false;
  bool _isPaused = false;
  bool _isExporting = false;
  bool _permissionDenied = false;
  String? _currentAudioPath;

  // Real-time Timer
  Timer? _timer;
  int _secondsElapsed = 0;

  // Blinking Red LED Animation Controller
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    // Pulse animation for recording badge
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnimation = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // ZERO-CLICK AUTO-RECORD: Trigger immediately after the first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startZeroClickAutoRecord();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    _projectController.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  /// ZERO-CLICK AUTO-RECORD: Request permission & start recording automatically
  Future<void> _startZeroClickAutoRecord() async {
    try {
      // 1. Request microphone permission
      final status = await Permission.microphone.request();

      if (!status.isGranted) {
        setState(() {
          _permissionDenied = true;
          _isRecording = false;
        });
        return;
      }

      setState(() => _permissionDenied = false);

      // 2. Prepare audio output path in application documents directory
      final docsDir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final timestampStr = _formatTimestamp(now);
      final audioFileName = 'quick_voice_$timestampStr.m4a';
      final audioPath = '${docsDir.path}/$audioFileName';

      // 3. Start audio recording directly in background
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: audioPath,
      );

      // 4. Update UI state & start real-time timer
      _currentAudioPath = audioPath;
      _secondsElapsed = 0;

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_isPaused && mounted) {
          setState(() {
            _secondsElapsed++;
          });
        }
      });

      _pulseController.repeat(reverse: true);

      setState(() {
        _isRecording = true;
        _isPaused = false;
      });

      // 5. Ensure Scratchpad TextField has keyboard focus immediately
      _notesFocusNode.requestFocus();
    } catch (e) {
      debugPrint('Auto-record error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ไม่สามารถเริ่มบันทึกเสียงอัตโนมัติ: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  /// Pause/Resume toggle for privacy or pauses during meetings
  Future<void> _togglePauseResume() async {
    if (!_isRecording) return;
    try {
      if (_isPaused) {
        await _audioRecorder.resume();
        _pulseController.repeat(reverse: true);
        setState(() => _isPaused = false);
      } else {
        await _audioRecorder.pause();
        _pulseController.stop();
        setState(() => _isPaused = true);
      }
    } catch (e) {
      debugPrint('Pause/Resume error: $e');
    }
  }

  /// Insert quick tags at current cursor position in Scratchpad
  void _insertQuickTag(String tag) {
    HapticFeedback.lightImpact();
    final text = _notesController.text;
    final selection = _notesController.selection;
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;

    final prefix =
        (start > 0 && !text.substring(0, start).endsWith('\n')) ? '\n' : '';
    final insertText = '$prefix$tag ';

    final newText = text.replaceRange(start, end, insertText);
    _notesController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insertText.length),
    );
    _notesFocusNode.requestFocus();
  }

  /// ONE-CLICK DUAL EXPORT:
  /// Stops recording, writes .txt file with AI analysis template, and invokes Native Share Sheet
  Future<void> _stopAndExport() async {
    if (_isExporting) return;
    HapticFeedback.heavyImpact();

    setState(() => _isExporting = true);

    try {
      // 1. Stop audio recording & finalize file
      String? finalAudioPath = _currentAudioPath;
      if (_isRecording) {
        finalAudioPath = await _audioRecorder.stop();
        _timer?.cancel();
        _pulseController.stop();
      }

      finalAudioPath ??= _currentAudioPath;
      if (finalAudioPath == null || !File(finalAudioPath).existsSync()) {
        throw Exception('ไม่พบไฟล์เสียงที่บันทึกไว้');
      }

      // 2. Prepare metadata
      final projectRaw = _projectController.text.trim();
      final projectName =
          projectRaw.isEmpty ? 'Quick_Meeting' : projectRaw;
      final safeProjectSlug = projectName
          .replaceAll(RegExp(r'[^\w\s\u0E00-\u0E7F-]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');

      final now = DateTime.now();
      final dateFormatted = _formatDisplayDate(now);
      final durationFormatted = _formatDuration(_secondsElapsed);
      final audioFileName = finalAudioPath.split(Platform.pathSeparator).last;

      // 3. Generate .txt Scratchpad + PM AI Analysis Prompt
      final docsDir = await getApplicationDocumentsDirectory();
      final txtFileName =
          'scratchpad_${safeProjectSlug}_${_formatTimestamp(now)}.txt';
      final txtFilePath = '${docsDir.path}/$txtFileName';

      final txtContent = _buildTxtReportContent(
        projectName: projectName,
        dateFormatted: dateFormatted,
        durationFormatted: durationFormatted,
        audioFileName: audioFileName,
        notesText: _notesController.text.trim(),
      );

      // 4. Save .txt file to disk
      final txtFile = File(txtFilePath);
      await txtFile.writeAsString(txtContent);

      setState(() {
        _isRecording = false;
        _isExporting = false;
      });

      // 5. Invoke Android Native Share Sheet with both .m4a and .txt files
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      final origin = renderBox != null
          ? renderBox.localToGlobal(Offset.zero) & renderBox.size
          : null;

      await Share.shareXFiles(
        [
          XFile(finalAudioPath, mimeType: 'audio/mp4'),
          XFile(txtFilePath, mimeType: 'text/plain'),
        ],
        text: 'รายงานและไฟล์เสียงการประชุม: $projectName\n'
            'ระยะเวลา: $durationFormatted | วันที่: $dateFormatted',
        subject: 'Quick Meeting Scratchpad & Audio - $projectName',
        sharePositionOrigin: origin,
      );

      // 6. Show Session Complete Modal with option to Start New Session
      if (mounted) {
        _showPostExportDialog(
          projectName: projectName,
          duration: durationFormatted,
          audioPath: finalAudioPath,
          txtPath: txtFilePath,
        );
      }
    } catch (e) {
      setState(() => _isExporting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาดในการส่งออก: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  /// Builds the complete .txt file containing Scratchpad notes and the AI PM Assistant Prompt
  String _buildTxtReportContent({
    required String projectName,
    required String dateFormatted,
    required String durationFormatted,
    required String audioFileName,
    required String notesText,
  }) {
    final cleanNotes =
        notesText.isEmpty ? '(ไม่มีข้อความใน Scratchpad)' : notesText;

    return '''
======================================================================
QUICK VOICE & SCRATCHPAD CAPTURE — PROJECT MANAGER NOTE
======================================================================
หัวข้อ / โปรเจกต์ : $projectName
วัน-เวลาที่บันทึก : $dateFormatted
ความยาวเสียง     : $durationFormatted
ไฟล์เสียงแนบ     : $audioFileName
======================================================================

[ข้อมูลนำเข้า: บันทึกโน้ตด่วน (Scratchpad)]
----------------------------------------------------------------------
$cleanNotes
----------------------------------------------------------------------

======================================================================
คำสั่งสำหรับ AI ในการวิเคราะห์และจัดทำรายงานสรุปการประชุม
======================================================================
คุณคือ AI ผู้ช่วย Project Manager 
ด้านล่างนี้คือ "บันทึกโน้ตด่วน (Scratchpad)" และ "ไฟล์เสียง/ข้อความถอดเสียงจากการคุยงานสด"

[ข้อมูลนำเข้า]
- โน้ตด่วนที่จดไว้:
"""
$cleanNotes
"""

- ข้อมูลเสียง:
แนบไฟล์เสียง $audioFileName หรือ วาง Transcript เสียงที่ถอดได้ที่นี่

---

คำสั่งในการวิเคราะห์และจัดทำรายงาน:
1. ใช้โน้ตด่วนเป็นตัวอ้างอิงหลักสำหรับชื่อคน, ศัพท์เทคนิค, เลขรุ่น หรือจุดสำคัญที่เน้นย้ำ
2. กรองการคุยเล่นทิ้ง สกัดออกมาเฉพาะเนื้อหางานจริง โดยสรุปออกมาใน 3 หัวข้อ:
   - 📌 สรุปสาระสำคัญ & มติที่ตกลงกัน (Key Decisions): ตกลงทำอะไร เพราะอะไร ใครเป็นคนตัดสินใจ
   - 🚀 ตาราง Action Items แยกตามรายบุคคล:
     | ชื่องาน | ผู้รับผิดชอบ | สิ่งที่ต้องส่งมอบ (Acceptance Criteria) | ความด่วน (Urgent / High / Med) |
   - ⚠️ จุดติดขัด / ความเสี่ยง / สิ่งที่ต้องตามต่อ (Blockers & Dependencies): งานนี้ต้องรอใครส่งของ หรือติดปัญหาอะไรอยู่หรือไม่
3. เขียนด้วยภาษาที่กระชับ ชัดเจน ตรงไปตรงมา เพื่อให้ก๊อปปี้ไปส่งต่อในแชททีมหรือนำไปเปิดตั๋วงานต่อได้ทันที
======================================================================
''';
  }

  /// Reset and start a fresh session immediately
  void _startNewSession() {
    _notesController.clear();
    _projectController.clear();
    _secondsElapsed = 0;
    _currentAudioPath = null;
    _startZeroClickAutoRecord();
  }

  /// Post-Export Dialog
  void _showPostExportDialog({
    required String projectName,
    required String duration,
    required String audioPath,
    required String txtPath,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 28),
            SizedBox(width: 10),
            Text(
              'ส่งออกข้อมูลสำเร็จ',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'โปรเจกต์: $projectName',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('ความยาวเสียง: $duration',
                style: const TextStyle(color: Color(0xFF94A3B8))),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('📦 ไฟล์ที่จัดเตรียม:',
                      style: TextStyle(
                          color: Color(0xFF38BDF8),
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text('• 🎵 ${audioPath.split(Platform.pathSeparator).last}',
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFCBD5E1))),
                  const SizedBox(height: 4),
                  Text('• 📝 ${txtPath.split(Platform.pathSeparator).last}',
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFCBD5E1))),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('ปิดหน้าต่าง',
                style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.fiber_manual_record_rounded,
                color: Colors.redAccent, size: 18),
            label: const Text('เริ่มคุยงานรอบใหม่ (Auto-Record)'),
            onPressed: () {
              Navigator.of(ctx).pop();
              _startNewSession();
            },
          ),
        ],
      ),
    );
  }

  // Formatting Utilities
  String _formatTimestamp(DateTime dt) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${pad(dt.month)}${pad(dt.day)}_${pad(dt.hour)}${pad(dt.minute)}${pad(dt.second)}';
  }

  String _formatDisplayDate(DateTime dt) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(dt.day)}/${pad(dt.month)}/${dt.year} ${pad(dt.hour)}:${pad(dt.minute)}:${pad(dt.second)}';
  }

  String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String pad(int n) => n.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${pad(hours)}:${pad(minutes)}:${pad(seconds)}';
    }
    return '${pad(minutes)}:${pad(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    final isTabletLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      // Top Navigation / Header Area
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.mic_none_rounded,
                  color: Color(0xFF818CF8), size: 24),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Quick Voice & Scratchpad',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
                ),
                Text(
                  'Tablet Mode for Project Managers',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Live Recording Status Badge
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _buildRecordingStatusBadge(),
          ),
        ],
      ),

      body: SafeArea(
        child: _permissionDenied
            ? _buildPermissionDeniedView()
            : _buildMainScratchpadLayout(isTabletLandscape),
      ),
    );
  }

  /// Live Recording Status Widget with pulsing red LED and timer
  Widget _buildRecordingStatusBadge() {
    if (!_isRecording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF334155),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text('READY',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white70)),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: _isPaused
            ? const Color(0xFFD97706).withOpacity(0.2)
            : const Color(0xFFEF4444).withOpacity(0.15),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: _isPaused
              ? const Color(0xFFF59E0B)
              : const Color(0xFFEF4444).withOpacity(0.6),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Blinking / Glowing Red Dot
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isPaused
                      ? const Color(0xFFF59E0B)
                      : Color.fromRGBO(239, 68, 68, _pulseAnimation.value),
                  boxShadow: _isPaused
                      ? []
                      : [
                          BoxShadow(
                            color: const Color(0xFFEF4444)
                                .withOpacity(_pulseAnimation.value * 0.7),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                ),
              );
            },
          ),
          const SizedBox(width: 8),

          // Status & Duration Timer
          Text(
            _isPaused
                ? 'PAUSED'
                : 'REC ${_formatDuration(_secondsElapsed)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
              letterSpacing: 0.5,
              color: _isPaused
                  ? const Color(0xFFFBBF24)
                  : const Color(0xFFFCA5A5),
            ),
          ),
          const SizedBox(width: 8),

          // Pause / Resume IconButton
          InkWell(
            onTap: _togglePauseResume,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                _isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Main Tablet Content Layout
  Widget _buildMainScratchpadLayout(bool isTabletLandscape) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isTabletLandscape ? 24.0 : 16.0,
        vertical: 12.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Project Title & Tag Input Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: TextField(
              controller: _projectController,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF8FAFC),
              ),
              decoration: const InputDecoration(
                icon: Icon(Icons.tag_rounded, color: Color(0xFF818CF8)),
                hintText: 'ชื่อโปรเจกต์ / แท็กหัวข้อ (เช่น [Pegasus] Sprint 42 Sync, Client Review)',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 2. Quick Scratchpad Tag Helper Pills
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildQuickTagPill(
                  label: '+ [📌 Decision]',
                  color: const Color(0xFF10B981),
                  onTap: () => _insertQuickTag('[📌 มติ/Decision]:'),
                ),
                _buildQuickTagPill(
                  label: '+ [🚀 Action]',
                  color: const Color(0xFF38BDF8),
                  onTap: () => _insertQuickTag('[🚀 มอบหมาย/Action]:'),
                ),
                _buildQuickTagPill(
                  label: '+ [⚠️ Blocker]',
                  color: const Color(0xFFF43F5E),
                  onTap: () => _insertQuickTag('[⚠️ จุดติดขัด/Blocker]:'),
                ),
                _buildQuickTagPill(
                  label: '+ [🕒 ${_formatDuration(_secondsElapsed)}]',
                  color: const Color(0xFFA855F7),
                  onTap: () => _insertQuickTag(
                      '[@${_formatDuration(_secondsElapsed)}]:'),
                ),
                _buildQuickTagPill(
                  label: '+ [👤 Speaker]',
                  color: const Color(0xFFEAB308),
                  onTap: () => _insertQuickTag('[👤 ผู้พูด]:'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3. Full-Screen Scratchpad Note Editor (Autofocus enabled)
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF131B2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1E293B)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: TextField(
                controller: _notesController,
                focusNode: _notesFocusNode,
                autofocus: true,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  fontSize: 18,
                  height: 1.6,
                  color: Color(0xFFF1F5F9),
                  letterSpacing: 0.2,
                ),
                decoration: const InputDecoration(
                  hintText:
                      'พิมพ์โน้ตด่วนที่นี่ทันที...\n'
                      '• ชื่อคน, ศัพท์เทคนิค, เลขรุ่น, สเปกสำคัญ\n'
                      '• มติที่คุยกันสดๆ\n'
                      '• งานที่ต้องส่งมอบ ใครรับผิดชอบ ส่งวันไหน\n'
                      '(ระบบกำลังอัดเสียงเบื้องหลังอัตโนมัติ ไม่ต้องกังวลเรื่องหลุดการคุย)',
                  hintMaxLines: 6,
                  hintStyle: TextStyle(
                    fontSize: 16,
                    height: 1.5,
                    color: Color(0xFF475569),
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 4. One-Click Dual Export Bottom Button
          SizedBox(
            height: 62,
            child: ElevatedButton(
              onPressed: _isExporting ? null : _stopAndExport,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626), // High-visibility Red
                foregroundColor: Colors.white,
                elevation: 4,
                shadowColor: const Color(0xFFDC2626).withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _isExporting
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                        SizedBox(width: 14),
                        Text(
                          'กำลังบันทึกและส่งออกไฟล์...',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.stop_circle_rounded, size: 28),
                        SizedBox(width: 10),
                        Text(
                          'Stop & Export (.m4a + .txt พร้อม Prompt AI)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.2,
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(Icons.share_rounded, size: 22),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Quick Tag Helper Button
  Widget _buildQuickTagPill({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  /// Permission Denied State View
  Widget _buildPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mic_off_rounded,
                color: Color(0xFFEF4444), size: 72),
            const SizedBox(height: 20),
            const Text(
              'ต้องการสิทธิ์การใช้งานไมโครโฟน',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              'แอปพลิเคชันนี้ออกแบบมาสำหรับการอัดเสียงด่วนอัตโนมัติ (Zero-Click)\nกรุณาอนุญาตสิทธิ์ไมโครโฟนเพื่อให้ระบบทำงานได้ทันทีเมื่อเปิดแอป',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _startZeroClickAutoRecord,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('ลองใหม่อีกครั้ง'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () => openAppSettings(),
                  icon: const Icon(Icons.settings_rounded),
                  label: const Text('เปิดการตั้งค่าแอป'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
