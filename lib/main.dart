import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Allow Tablet Landscape & Portrait orientations
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFF1E293B),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const StarNoteVoiceApp());
}

/// Root Application Widget
class StarNoteVoiceApp extends StatelessWidget {
  const StarNoteVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StarNote Quick Capture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF4EFE6), // Warm paper tone
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E293B),
          brightness: Brightness.light,
        ),
        fontFamily: 'sans-serif',
      ),
      home: const StarNoteScreen(),
    );
  }
}

/// Paper Styles for StarNote Canvas
enum PaperStyle { ruled, grid, blank }

/// Pen Tools
enum PenTool { pen, highlighter, eraser }

/// Stroke Model for Digital Ink
class DrawnStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final bool isHighlighter;

  DrawnStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isHighlighter = false,
  });

  DrawnStroke copyWith({List<Offset>? points}) {
    return DrawnStroke(
      points: points ?? List.from(this.points),
      color: color,
      strokeWidth: strokeWidth,
      isHighlighter: isHighlighter,
    );
  }
}

/// Main StarNote Tablet Screen
class StarNoteScreen extends StatefulWidget {
  const StarNoteScreen({super.key});

  @override
  State<StarNoteScreen> createState() => _StarNoteScreenState();
}

class _StarNoteScreenState extends State<StarNoteScreen>
    with SingleTickerProviderStateMixin {
  // GlobalKey for Capturing High-Res PNG of the Canvas
  final GlobalKey _canvasRepaintKey = GlobalKey();

  // Text Controllers
  final TextEditingController _projectController = TextEditingController();
  final TextEditingController _typedNotesController = TextEditingController();
  final FocusNode _typedFocusNode = FocusNode();

  // Mode: Pen Handwriting Canvas vs Typed Scratchpad
  bool _isPenMode = true;

  // Audio Recording Engine
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _isPaused = false;
  bool _isExporting = false;
  bool _permissionDenied = false;
  String? _currentAudioPath;

  // Drift-Free Timer
  Timer? _timer;
  int _secondsElapsed = 0;

  // Blinking Red LED Animation Controller
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // Handwriting Ink State
  final List<DrawnStroke> _strokes = [];
  final List<List<DrawnStroke>> _undoStack = [];
  final List<List<DrawnStroke>> _redoStack = [];
  DrawnStroke? _activeStroke;

  // Pen Configuration
  PenTool _currentTool = PenTool.pen;
  Color _penColor = const Color(0xFF1E293B); // Obsidian Ink
  double _strokeWidth = 3.2; // Medium pen tip
  PaperStyle _paperStyle = PaperStyle.ruled;
  bool _isDarkPaper = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnimation = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // ZERO-CLICK AUTO-RECORD: Start audio recording automatically on app launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startZeroClickAutoRecord();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    _projectController.dispose();
    _typedNotesController.dispose();
    _typedFocusNode.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  /// ZERO-CLICK AUTO-RECORD: Request mic permission & record immediately
  Future<void> _startZeroClickAutoRecord() async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        setState(() {
          _permissionDenied = true;
          _isRecording = false;
        });
        return;
      }

      setState(() => _permissionDenied = false);

      final docsDir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final timestamp = _formatTimestamp(now);
      final audioFileName = 'starnote_voice_$timestamp.m4a';
      final audioPath = '${docsDir.path}/$audioFileName';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: audioPath,
      );

      _currentAudioPath = audioPath;
      _secondsElapsed = 0;

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_isPaused && mounted) {
          setState(() => _secondsElapsed++);
        }
      });

      _pulseController.repeat(reverse: true);
      setState(() {
        _isRecording = true;
        _isPaused = false;
      });
    } catch (e) {
      debugPrint('Auto-record error: $e');
    }
  }

  /// Pause / Resume Audio Toggle
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
      debugPrint('Pause error: $e');
    }
  }

  // --- DIGITAL INK HANDWRITING GESTURE HANDLERS ---

  void _onPointerDown(PointerDownEvent event) {
    final localPos = event.localPosition;

    if (_currentTool == PenTool.eraser) {
      _saveStateForUndo();
      _eraseAtPoint(localPos);
      return;
    }

    _saveStateForUndo();

    final isHighlighter = _currentTool == PenTool.highlighter;
    final width = isHighlighter ? 18.0 : _strokeWidth;
    final color = isHighlighter
        ? const Color(0xFFFDE047) // Soft Neon Yellow Highlighter
        : _penColor;

    setState(() {
      _activeStroke = DrawnStroke(
        points: [localPos],
        color: color,
        strokeWidth: width,
        isHighlighter: isHighlighter,
      );
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final localPos = event.localPosition;

    if (_currentTool == PenTool.eraser) {
      _eraseAtPoint(localPos);
      return;
    }

    if (_activeStroke != null) {
      setState(() {
        _activeStroke!.points.add(localPos);
      });
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_currentTool == PenTool.eraser) return;

    if (_activeStroke != null) {
      setState(() {
        _strokes.add(_activeStroke!);
        _activeStroke = null;
        _redoStack.clear();
      });
    }
  }

  /// Stroke Eraser: Erases any stroke intersecting the eraser point
  void _eraseAtPoint(Offset point) {
    const double eraseRadius = 24.0;
    const double eraseRadiusSq = eraseRadius * eraseRadius;

    final initialCount = _strokes.length;
    _strokes.removeWhere((stroke) {
      for (final p in stroke.points) {
        final dx = p.dx - point.dx;
        final dy = p.dy - point.dy;
        if (dx * dx + dy * dy <= eraseRadiusSq) {
          return true;
        }
      }
      return false;
    });

    if (_strokes.length != initialCount) {
      HapticFeedback.selectionClick();
      setState(() {});
    }
  }

  void _saveStateForUndo() {
    _undoStack.add(List.from(_strokes));
    if (_undoStack.length > 30) {
      _undoStack.removeAt(0);
    }
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      _redoStack.add(List.from(_strokes));
      _strokes.clear();
      _strokes.addAll(_undoStack.removeLast());
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      _undoStack.add(List.from(_strokes));
      _strokes.clear();
      _strokes.addAll(_redoStack.removeLast());
    });
  }

  void _clearCanvas() {
    if (_strokes.isEmpty) return;
    HapticFeedback.mediumImpact();
    _saveStateForUndo();
    setState(() {
      _strokes.clear();
      _redoStack.clear();
    });
  }

  // --- ONE-CLICK DUAL EXPORT (Audio .m4a + Handwritten PNG + AI Prompt .txt) ---

  Future<void> _stopAndExport() async {
    if (_isExporting) return;
    HapticFeedback.heavyImpact();

    setState(() => _isExporting = true);

    try {
      // 1. Stop Audio Recording
      String? finalAudioPath = _currentAudioPath;
      if (_isRecording) {
        finalAudioPath = await _audioRecorder.stop();
        _timer?.cancel();
        _pulseController.stop();
      }
      finalAudioPath ??= _currentAudioPath;

      // 2. Capture Handwriting Canvas into High-Resolution PNG (StarNote Image)
      String? handwrittenImagePath;
      if (_strokes.isNotEmpty) {
        final boundary = _canvasRepaintKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
        if (boundary != null) {
          final ui.Image image = await boundary.toImage(pixelRatio: 2.5);
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.png);
          if (byteData != null) {
            final docsDir = await getApplicationDocumentsDirectory();
            final nowStr = _formatTimestamp(DateTime.now());
            final imgFile = File('${docsDir.path}/starnote_$nowStr.png');
            await imgFile.writeAsBytes(byteData.buffer.asUint8List());
            handwrittenImagePath = imgFile.path;
          }
        }
      }

      // 3. Prepare Metadata & Report
      final now = DateTime.now();
      final projectRaw = _projectController.text.trim();
      final projectName =
          projectRaw.isEmpty ? 'StarNote_Meeting' : projectRaw;
      final safeProjectSlug = projectName
          .replaceAll(RegExp(r'[^\w\s\u0E00-\u0E7F-]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');

      final docsDir = await getApplicationDocumentsDirectory();
      final txtFileName =
          'starnote_${safeProjectSlug}_${_formatTimestamp(now)}.txt';
      final txtFilePath = '${docsDir.path}/$txtFileName';

      final audioFileName = finalAudioPath != null
          ? finalAudioPath.split(Platform.pathSeparator).last
          : 'ไม่มีไฟล์เสียง';
      final imageFileName = handwrittenImagePath != null
          ? handwrittenImagePath.split(Platform.pathSeparator).last
          : 'ไม่มีโน้ตลายมือ';

      final txtContent = _buildTxtReportContent(
        projectName: projectName,
        dateFormatted: _formatDisplayDate(now),
        durationFormatted: _formatDuration(_secondsElapsed),
        audioFileName: audioFileName,
        imageFileName: imageFileName,
        typedNotes: _typedNotesController.text.trim(),
      );

      await File(txtFilePath).writeAsString(txtContent);

      setState(() {
        _isRecording = false;
        _isExporting = false;
      });

      // 4. Invoke Android Native Share Sheet
      final shareFiles = <XFile>[];
      if (finalAudioPath != null && File(finalAudioPath).existsSync()) {
        shareFiles.add(XFile(finalAudioPath, mimeType: 'audio/mp4'));
      }
      if (handwrittenImagePath != null &&
          File(handwrittenImagePath).existsSync()) {
        shareFiles.add(XFile(handwrittenImagePath, mimeType: 'image/png'));
      }
      shareFiles.add(XFile(txtFilePath, mimeType: 'text/plain'));

      final renderBox = context.findRenderObject() as RenderBox?;
      final origin = renderBox != null
          ? renderBox.localToGlobal(Offset.zero) & renderBox.size
          : null;

      await Share.shareXFiles(
        shareFiles,
        text: 'StarNote Meeting Capture: $projectName\n'
            'บันทึกเสียง + ภาพโน้ตลายมือปากกา + คำสั่งวิเคราะห์ AI พร้อมใช้งาน',
        subject: 'StarNote Capture - $projectName',
        sharePositionOrigin: origin,
      );

      // 5. Post-Export Dialog
      if (mounted) {
        _showPostExportDialog(
          projectName: projectName,
          duration: _formatDuration(_secondsElapsed),
          audioPath: finalAudioPath,
          imgPath: handwrittenImagePath,
          txtPath: txtFilePath,
        );
      }
    } catch (e) {
      setState(() => _isExporting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ข้อผิดพลาดในการส่งออก: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  String _buildTxtReportContent({
    required String projectName,
    required String dateFormatted,
    required String durationFormatted,
    required String audioFileName,
    required String imageFileName,
    required String typedNotes,
  }) {
    return '''
======================================================================
STARNOTE QUICK VOICE & PEN CAPTURE — PROJECT MANAGER REPORT
======================================================================
หัวข้อ / โปรเจกต์ : $projectName
วัน-เวลาที่บันทึก : $dateFormatted
ความยาวเสียง     : $durationFormatted
ไฟล์เสียงแนบ     : $audioFileName
ภาพโน้ตลายมือ    : $imageFileName
======================================================================

[ข้อมูลนำเข้า: บันทึกพิมพ์เพิ่มเติม (Typed Scratchpad)]
----------------------------------------------------------------------
${typedNotes.isEmpty ? '(เน้นจดด้วยปากกาในไฟล์ภาพ $imageFileName)' : typedNotes}
----------------------------------------------------------------------

======================================================================
คำสั่งสำหรับ AI ในการวิเคราะห์และจัดทำรายงานสรุปการประชุม
======================================================================
คุณคือ AI ผู้ช่วย Project Manager 
ด้านล่างนี้คือ "ภาพโน้ตลายมือปากกา (Handwritten Notes ในไฟล์ $imageFileName)" 
และ "ไฟล์เสียง/ข้อความถอดเสียงจากการคุยงานสด ($audioFileName)"

[ข้อมูลนำเข้า]
- โน้ตด่วนที่จดไว้:
"""
(โปรดอ่านข้อความและแผนภาพจากภาพลายมือ $imageFileName ที่แนบมาด้วย)
${typedNotes.isNotEmpty ? '\nโน้ตพิมพ์เพิ่มเติม:\n$typedNotes' : ''}
"""

- ข้อมูลเสียง:
แนบไฟล์เสียง $audioFileName หรือ วาง Transcript เสียงที่ถอดได้ที่นี่

---

คำสั่งในการวิเคราะห์และจัดทำรายงาน:
1. ใช้ภาพโน้ตลายมือปากกาเป็นตัวอ้างอิงหลักสำหรับชื่อคน, ศัพท์เทคนิค, เลขรุ่น หรือจุดสำคัญที่เน้นย้ำ
2. กรองการคุยเล่นทิ้ง สกัดออกมาเฉพาะเนื้อหางานจริง โดยสรุปออกมาใน 3 หัวข้อ:
   - 📌 สรุปสาระสำคัญ & มติที่ตกลงกัน (Key Decisions): ตกลงทำอะไร เพราะอะไร ใครเป็นคนตัดสินใจ
   - 🚀 ตาราง Action Items แยกตามรายบุคคล:
     | ชื่องาน | ผู้รับผิดชอบ | สิ่งที่ต้องส่งมอบ (Acceptance Criteria) | ความด่วน (Urgent / High / Med) |
   - ⚠️ จุดติดขัด / ความเสี่ยง / สิ่งที่ต้องตามต่อ (Blockers & Dependencies): งานนี้ต้องรอใครส่งของ หรือติดปัญหาอะไรอยู่หรือไม่
3. เขียนด้วยภาษาที่กระชับ ชัดเจน ตรงไปตรงมา เพื่อให้ก๊อปปี้ไปส่งต่อในแชททีมหรือนำไปเปิดตั๋วงานต่อได้ทันที
======================================================================
''';
  }

  void _startNewSession() {
    _strokes.clear();
    _undoStack.clear();
    _redoStack.clear();
    _typedNotesController.clear();
    _projectController.clear();
    _secondsElapsed = 0;
    _currentAudioPath = null;
    _startZeroClickAutoRecord();
  }

  void _showPostExportDialog({
    required String projectName,
    required String duration,
    String? audioPath,
    String? imgPath,
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
            Icon(Icons.check_circle_rounded,
                color: Color(0xFF10B981), size: 28),
            SizedBox(width: 10),
            Text('ส่งออกข้อมูลสำเร็จ',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('โปรเจกต์: $projectName',
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: Colors.white)),
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
                  const Text('📦 ไฟล์ที่จัดเตรียมเรียบร้อย:',
                      style: TextStyle(
                          color: Color(0xFF38BDF8),
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  if (audioPath != null)
                    Text('• 🎵 ${audioPath.split(Platform.pathSeparator).last}',
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFFCBD5E1))),
                  if (imgPath != null)
                    Text('• ✍️ ${imgPath.split(Platform.pathSeparator).last}',
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFFCBD5E1))),
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
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.fiber_manual_record_rounded,
                color: Colors.redAccent, size: 18),
            label: const Text('เริ่มจดรอบใหม่ (Auto-Record)'),
            onPressed: () {
              Navigator.of(ctx).pop();
              _startNewSession();
            },
          ),
        ],
      ),
    );
  }

  // Utilities
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
    return Scaffold(
      backgroundColor:
          _isDarkPaper ? const Color(0xFF111827) : const Color(0xFFF9F6F0),
      appBar: _buildTopAppBar(),
      body: SafeArea(
        child: _permissionDenied
            ? _buildPermissionDeniedView()
            : Column(
                children: [
                  // Stylus Pen Toolbar (StarNote Palette)
                  _buildPenToolbar(),

                  // Full Canvas Area (Handwriting vs Typed)
                  Expanded(
                    child: _isPenMode
                        ? _buildHandwritingCanvas()
                        : _buildTypedScratchpad(),
                  ),

                  // Bottom Action Bar: One-Click Dual Export
                  _buildBottomControlBar(),
                ],
              ),
      ),
    );
  }

  /// Top App Bar with Project Name & Live Recording Indicator
  PreferredSizeWidget _buildTopAppBar() {
    return AppBar(
      backgroundColor:
          _isDarkPaper ? const Color(0xFF0F172A) : const Color(0xFFEFE9DE),
      elevation: 0,
      titleSpacing: 16,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.gesture_rounded,
                color: Color(0xFF38BDF8), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _projectController,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _isDarkPaper ? Colors.white : const Color(0xFF1E293B),
                ),
                decoration: InputDecoration(
                  hintText: 'ชื่อการคุยงาน / โปรเจกต์ (เช่น Sprint Sync, สเปกเครื่องใหม่)',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: _isDarkPaper
                        ? const Color(0xFF64748B)
                        : const Color(0xFF94A3B8),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        // Mode Switcher: Pen vs Keyboard
        IconButton(
          tooltip: _isPenMode ? 'สลับไปโหมดพิมพ์' : 'สลับไปโหมดจดปากกา',
          icon: Icon(
            _isPenMode ? Icons.keyboard_rounded : Icons.edit_note_rounded,
            color: _isDarkPaper ? Colors.white70 : const Color(0xFF334155),
          ),
          onPressed: () {
            setState(() => _isPenMode = !_isPenMode);
          },
        ),

        // Live Recording Status Badge
        Padding(
          padding: const EdgeInsets.only(right: 14, left: 6),
          child: _buildRecordingStatusBadge(),
        ),
      ],
    );
  }

  /// Real-Time Recording Status Badge
  Widget _buildRecordingStatusBadge() {
    if (!_isRecording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade400,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text('READY',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: _isPaused
            ? const Color(0xFFF59E0B).withOpacity(0.2)
            : const Color(0xFFEF4444).withOpacity(0.18),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: _isPaused
              ? const Color(0xFFF59E0B)
              : const Color(0xFFEF4444).withOpacity(0.7),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Container(
                width: 10,
                height: 10,
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
                            blurRadius: 6,
                            spreadRadius: 1.5,
                          ),
                        ],
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Text(
            _isPaused
                ? 'PAUSED'
                : 'REC ${_formatDuration(_secondsElapsed)}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: _isPaused
                  ? const Color(0xFFD97706)
                  : const Color(0xFFDC2626),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: _togglePauseResume,
            child: Icon(
              _isPaused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              size: 18,
              color: _isPaused
                  ? const Color(0xFFD97706)
                  : const Color(0xFFDC2626),
            ),
          ),
        ],
      ),
    );
  }

  /// StarNote Pen & Stylus Toolbar
  Widget _buildPenToolbar() {
    final activeBg =
        _isDarkPaper ? const Color(0xFF1E293B) : const Color(0xFFEAE3D2);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: activeBg,
      child: Row(
        children: [
          // Tool: Pen
          _buildToolButton(
            icon: Icons.edit_rounded,
            tooltip: 'ปากกาหมึก (Pen)',
            isActive: _currentTool == PenTool.pen,
            onTap: () => setState(() => _currentTool = PenTool.pen),
          ),
          const SizedBox(width: 6),

          // Tool: Highlighter
          _buildToolButton(
            icon: Icons.brush_rounded,
            tooltip: 'ปากกาเน้นข้อความ (Highlighter)',
            isActive: _currentTool == PenTool.highlighter,
            onTap: () => setState(() => _currentTool = PenTool.highlighter),
          ),
          const SizedBox(width: 6),

          // Tool: Eraser
          _buildToolButton(
            icon: Icons.auto_fix_high_rounded,
            tooltip: 'ยางลบแตะเส้น (Stroke Eraser)',
            isActive: _currentTool == PenTool.eraser,
            onTap: () => setState(() => _currentTool = PenTool.eraser),
          ),
          const SizedBox(width: 16),
          const VerticalDivider(width: 1, thickness: 1, indent: 6, endIndent: 6),
          const SizedBox(width: 16),

          // Color Palette (When using Pen)
          if (_currentTool == PenTool.pen) ...[
            _buildColorCircle(const Color(0xFF1E293B)), // Obsidian Black
            _buildColorCircle(const Color(0xFF1D4ED8)), // Deep Royal Blue
            _buildColorCircle(const Color(0xFFDC2626)), // Crimson Red
            _buildColorCircle(const Color(0xFF059669)), // Forest Green
            const SizedBox(width: 14),
          ],

          // Stroke Thickness Selector
          if (_currentTool != PenTool.eraser) ...[
            _buildThicknessButton(2.0, 'หัวเล็ก'),
            _buildThicknessButton(3.5, 'หัวกลาง'),
            _buildThicknessButton(5.5, 'หัวใหญ่'),
            const SizedBox(width: 14),
          ],

          const Spacer(),

          // Undo / Redo
          IconButton(
            icon: const Icon(Icons.undo_rounded, size: 22),
            tooltip: 'ย้อนกลับ (Undo)',
            onPressed: _undoStack.isNotEmpty ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo_rounded, size: 22),
            tooltip: 'ทำซ้ำ (Redo)',
            onPressed: _redoStack.isNotEmpty ? _redo : null,
          ),

          // Paper Background Toggle (Ruled / Grid / Blank)
          PopupMenuButton<PaperStyle>(
            icon: const Icon(Icons.layers_outlined, size: 22),
            tooltip: 'สไตล์กระดาษ',
            onSelected: (style) => setState(() => _paperStyle = style),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: PaperStyle.ruled,
                child: Text('กระดาษมีเส้นบรรทัด (Ruled Paper)'),
              ),
              const PopupMenuItem(
                value: PaperStyle.grid,
                child: Text('กระดาษตารางกริด (Grid Paper)'),
              ),
              const PopupMenuItem(
                value: PaperStyle.blank,
                child: Text('กระดาษว่างเปล่า (Blank Canvas)'),
              ),
            ],
          ),

          // Dark / Cream Paper Mode Toggle
          IconButton(
            icon: Icon(
              _isDarkPaper
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
              size: 22,
            ),
            tooltip: 'สลับกระดาษถนอมสายตา / โหมดมืด',
            onPressed: () {
              setState(() {
                _isDarkPaper = !_isDarkPaper;
                if (_isDarkPaper && _penColor == const Color(0xFF1E293B)) {
                  _penColor = const Color(0xFFF8FAFC);
                } else if (!_isDarkPaper &&
                    _penColor == const Color(0xFFF8FAFC)) {
                  _penColor = const Color(0xFF1E293B);
                }
              });
            },
          ),

          // Clear Page
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined,
                size: 22, color: Color(0xFFDC2626)),
            tooltip: 'ล้างหน้ากระดาษ (Clear Page)',
            onPressed: _strokes.isNotEmpty ? _clearCanvas : null,
          ),
        ],
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1E293B) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isActive
                ? Colors.white
                : (_isDarkPaper ? Colors.white70 : const Color(0xFF334155)),
          ),
        ),
      ),
    );
  }

  Widget _buildColorCircle(Color color) {
    final isSelected = _penColor == color;
    return GestureDetector(
      onTap: () => setState(() => _penColor = color),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? const Color(0xFF38BDF8) : Colors.white,
            width: isSelected ? 2.5 : 1.5,
          ),
          boxShadow: [
            if (isSelected)
              BoxShadow(
                color: color.withOpacity(0.5),
                blurRadius: 6,
                spreadRadius: 1,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThicknessButton(double width, String label) {
    final isSelected = (_strokeWidth - width).abs() < 0.2;
    return GestureDetector(
      onTap: () => setState(() => _strokeWidth = width),
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1E293B) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected
                ? Colors.white
                : (_isDarkPaper ? Colors.white70 : const Color(0xFF475569)),
          ),
        ),
      ),
    );
  }

  /// StarNote Digital Ink Handwriting Canvas
  Widget _buildHandwritingCanvas() {
    final paperColor =
        _isDarkPaper ? const Color(0xFF111827) : const Color(0xFFFDFBF7);
    final lineColor =
        _isDarkPaper ? const Color(0xFF1F2937) : const Color(0xFFE2DDD5);

    return RepaintBoundary(
      key: _canvasRepaintKey,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: CustomPaint(
          size: Size.infinite,
          painter: StarNoteCanvasPainter(
            strokes: _strokes,
            activeStroke: _activeStroke,
            paperStyle: _paperStyle,
            paperColor: paperColor,
            lineColor: lineColor,
          ),
        ),
      ),
    );
  }

  /// Fallback Typed Scratchpad (when user wants keyboard)
  Widget _buildTypedScratchpad() {
    return Container(
      padding: const EdgeInsets.all(20),
      color: _isDarkPaper ? const Color(0xFF111827) : const Color(0xFFFDFBF7),
      child: TextField(
        controller: _typedNotesController,
        focusNode: _typedFocusNode,
        maxLines: null,
        expands: true,
        style: TextStyle(
          fontSize: 18,
          height: 1.6,
          color: _isDarkPaper ? Colors.white : const Color(0xFF1E293B),
        ),
        decoration: InputDecoration(
          hintText: 'พิมพ์โน้ตการคุยงานที่นี่...\n'
              '(สามารถสลับกลับไปที่โหมดปากกาที่มุมขวาบนได้ตลอดเวลา)',
          hintStyle: TextStyle(
            color: _isDarkPaper
                ? const Color(0xFF475569)
                : const Color(0xFF94A3B8),
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  /// Bottom Control Bar: One-Click Dual Export
  Widget _buildBottomControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: _isDarkPaper ? const Color(0xFF0F172A) : Colors.white,
        border: Border(
          top: BorderSide(
            color: _isDarkPaper
                ? const Color(0xFF1E293B)
                : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: Row(
        children: [
          // Info summary
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '✍️ โน้ตปากกา: ${_strokes.length} เส้น | 🎙️ เสียง: ${_formatDuration(_secondsElapsed)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _isDarkPaper
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'ส่งออกไฟล์เสียง (.m4a) + ภาพลายมือ (.png) + Prompt AI (.txt)',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
          const Spacer(),

          // Giant Stop & Export Button
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isExporting ? null : _stopAndExport,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626), // High-visibility red
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isExporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.stop_circle_rounded, size: 22),
              label: Text(
                _isExporting ? 'กำลังส่งออก...' : 'Stop & Export All',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Permission Denied View
  Widget _buildPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mic_off_rounded,
                color: Color(0xFFEF4444), size: 64),
            const SizedBox(height: 16),
            const Text(
              'ต้องการสิทธิ์ไมโครโฟนเพื่อบันทึกเสียงอัตโนมัติ',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'กรุณาอนุญาตสิทธิ์ไมโครโฟนเพื่อให้แอปเริ่มอัดเสียงทันทีที่เปิดแอป',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _startZeroClickAutoRecord,
              child: const Text('อนุญาตสิทธิ์และเริ่มใช้งาน'),
            ),
          ],
        ),
      ),
    );
  }
}

/// StarNote Canvas Custom Painter with Bezier Path Smoothing and Ruled Paper Guides
class StarNoteCanvasPainter extends CustomPainter {
  final List<DrawnStroke> strokes;
  final DrawnStroke? activeStroke;
  final PaperStyle paperStyle;
  final Color paperColor;
  final Color lineColor;

  StarNoteCanvasPainter({
    required this.strokes,
    required this.activeStroke,
    required this.paperStyle,
    required this.paperColor,
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw Paper Background
    final bgPaint = Paint()..color = paperColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // 2. Draw Paper Guidelines
    _drawPaperGrid(canvas, size);

    // 3. Draw Completed Strokes
    for (final stroke in strokes) {
      _drawSmoothStroke(canvas, stroke);
    }

    // 4. Draw Currently Active Stroke
    if (activeStroke != null) {
      _drawSmoothStroke(canvas, activeStroke!);
    }
  }

  void _drawPaperGrid(Canvas canvas, Size size) {
    if (paperStyle == PaperStyle.blank) return;

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0;

    if (paperStyle == PaperStyle.ruled) {
      const double lineSpacing = 36.0;
      const double topMargin = 50.0;
      for (double y = topMargin; y < size.height; y += lineSpacing) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
      }
    } else if (paperStyle == PaperStyle.grid) {
      const double spacing = 32.0;
      for (double x = 0; x < size.width; x += spacing) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
      }
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
      }
    }
  }

  void _drawSmoothStroke(Canvas canvas, DrawnStroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.isHighlighter
          ? stroke.color.withOpacity(0.38)
          : stroke.color
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (stroke.points.length == 1) {
      final dotPaint = Paint()
        ..color = paint.color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(stroke.points.first, stroke.strokeWidth / 2, dotPaint);
      return;
    }

    // Quadratic Bezier smoothing for natural pen ink
    final path = Path();
    path.moveTo(stroke.points[0].dx, stroke.points[0].dy);

    for (int i = 1; i < stroke.points.length - 1; i++) {
      final p0 = stroke.points[i];
      final p1 = stroke.points[i + 1];
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
    path.lineTo(stroke.points.last.dx, stroke.points.last.dy);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant StarNoteCanvasPainter oldDelegate) => true;
}
