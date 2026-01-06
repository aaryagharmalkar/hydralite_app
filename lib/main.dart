import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ================= CONFIGURATION =================
class AppConfig {
  static const String appTitle = "Medical Audio Transcription";
  static const String appVersion = "1.0.0";

  // Server configuration
  static String baseUrl = "https://hydralite-backend.onrender.com";

  // Timeouts
  static const Duration connectionTimeout = Duration(seconds: 5);
  static const Duration uploadTimeout = Duration(minutes: 10);
  static const Duration downloadTimeout = Duration(minutes: 2);

  // Polling configuration
  static const Duration statusPollInterval = Duration(seconds: 5);
  static const Duration statusCacheDuration = Duration(seconds: 2);

  // File constraints
  static const int maxFileSizeMB = 100;
  static const List<String> allowedExtensions = [
    '.wav', '.mp3', '.m4a', '.aac', '.ogg', '.3gp'
  ];

  // UI
  static const int maxRetries = 3;
  static const Duration retryDelay = Duration(seconds: 2);
}

// ================= LOGGING =================
class AppLogger {
  static void info(String message) {
    debugPrint('[INFO] ${DateTime.now()}: $message');
  }

  static void warning(String message) {
    debugPrint('[WARNING] ${DateTime.now()}: $message');
  }

  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    debugPrint('[ERROR] ${DateTime.now()}: $message');
    if (error != null) debugPrint('Error: $error');
    if (stackTrace != null) debugPrint('Stack trace: $stackTrace');
  }
}

// ================= MODELS =================
class ProcessingStatus {
  final String stage;
  final String message;
  final int progress;
  final String? file;
  final String? language;
  final String? source;
  final String? error;
  final int? timestamp;

  ProcessingStatus({
    required this.stage,
    required this.message,
    required this.progress,
    this.file,
    this.language,
    this.source,
    this.error,
    this.timestamp,
  });

  factory ProcessingStatus.fromJson(Map<String, dynamic> json) {
    return ProcessingStatus(
      stage: json['stage'] ?? 'unknown',
      message: json['message'] ?? '',
      progress: json['progress'] ?? 0,
      file: json['file'],
      language: json['language'],
      source: json['source'],
      error: json['error'],
      timestamp: json['timestamp'],
    );
  }

  bool get isCompleted => stage == 'completed';
  bool get isError => stage == 'error';
  bool get isProcessing => !isCompleted && !isError && stage != 'idle';
}

class ProcessStep {
  final String key;
  final String label;
  final String icon;

  const ProcessStep({
    required this.key,
    required this.label,
    required this.icon,
  });
}

// ================= PROCESS STEPS =================
const List<ProcessStep> processSteps = [
  ProcessStep(key: "uploading", label: "Uploading audio", icon: "📤"),
  ProcessStep(key: "transcribing", label: "Transcribing speech", icon: "🎙️"),
  ProcessStep(key: "summarizing", label: "Analyzing conversation", icon: "🧠"),
  ProcessStep(key: "generating_pdf", label: "Generating report", icon: "📄"),
  ProcessStep(key: "completed", label: "Completed", icon: "✅"),
];

// ================= API SERVICE =================
class ApiService {
  final String baseUrl;

  ApiService({required this.baseUrl});

  // Health check
  Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(AppConfig.connectionTimeout);

      if (response.statusCode == 200) {
        AppLogger.info('Health check successful');
        return true;
      }

      AppLogger.warning('Health check failed with status: ${response.statusCode}');
      return false;
    } catch (e, stackTrace) {
      AppLogger.error('Health check error', e, stackTrace);
      return false;
    }
  }

  // Get processing status
  Future<ProcessingStatus?> getStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(AppConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return ProcessingStatus.fromJson(data);
      }

      AppLogger.warning('Status request failed: ${response.statusCode}');
      return null;
    } catch (e, stackTrace) {
      AppLogger.error('Failed to fetch status', e, stackTrace);
      return null;
    }
  }

  // Upload audio file
  Future<String?> uploadAudio(PlatformFile file) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/upload-audio'),
      );

      // Use file path when available (more efficient)
      if (file.path != null && file.path!.isNotEmpty) {
        request.files.add(
          await http.MultipartFile.fromPath('file', file.path!),
        );
      } else if (file.bytes != null) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            file.bytes!,
            filename: file.name,
          ),
        );
      } else {
        throw Exception('No file data available');
      }

      AppLogger.info('Starting upload: ${file.name}');

      final streamedResponse = await request.send().timeout(
        AppConfig.uploadTimeout,
        onTimeout: () => throw TimeoutException('Upload timed out'),
      );

      if (streamedResponse.statusCode == 200) {
        final responseBody = await streamedResponse.stream.bytesToString();
        final data = jsonDecode(responseBody);

        AppLogger.info('Upload successful: ${data['audio_name']}');
        return data['audio_name'];
      }

      if (streamedResponse.statusCode == 413) {
        throw Exception('File too large (max ${AppConfig.maxFileSizeMB}MB)');
      }

      if (streamedResponse.statusCode == 400) {
        throw Exception('Invalid file format');
      }

      throw Exception('Upload failed with status ${streamedResponse.statusCode}');
    } catch (e, stackTrace) {
      AppLogger.error('Upload failed', e, stackTrace);
      rethrow;
    }
  }

  // Download PDF
  Future<File> downloadPdf(String audioName) async {
    try {
      AppLogger.info('Downloading PDF for: $audioName');

      final response = await http
          .get(Uri.parse('$baseUrl/download-pdf/$audioName'))
          .timeout(AppConfig.downloadTimeout);

      if (response.statusCode == 404) {
        throw Exception('PDF not found');
      }

      if (response.statusCode != 200) {
        throw Exception('Download failed');
      }

      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/summary_$timestamp.pdf');

      await file.writeAsBytes(response.bodyBytes);

      AppLogger.info('PDF saved: ${file.path}');
      return file;
    } catch (e, stackTrace) {
      AppLogger.error('Download failed', e, stackTrace);
      rethrow;
    }
  }
}

// ================= MAIN APP =================
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ================= HOME PAGE =================
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final ApiService _apiService;

  // State
  PlatformFile? _selectedFile;
  ProcessingStatus? _status;
  String? _currentFileId;
  bool _isUploading = false;
  bool _isDownloading = false;
  bool _serverConnected = false;

  // Polling
  Timer? _statusTimer;
  DateTime? _lastStatusFetch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume polling when app comes to foreground
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else if (state == AppLifecycleState.paused) {
      _statusTimer?.cancel();
    }
  }

  // ================= INITIALIZATION =================
  Future<void> _initializeApp() async {
    await _loadServerUrl();
    _apiService = ApiService(baseUrl: AppConfig.baseUrl);
    await _testConnection();
    _startPolling();
  }

  Future<void> _loadServerUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('server_url');
      if (savedUrl != null && savedUrl.isNotEmpty) {
        AppConfig.baseUrl = savedUrl;
        AppLogger.info('Loaded server URL: $savedUrl');
      }
    } catch (e) {
      AppLogger.warning('Failed to load server URL: $e');
    }
  }

  Future<void> _saveServerUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', url);
      AppLogger.info('Saved server URL: $url');
    } catch (e) {
      AppLogger.warning('Failed to save server URL: $e');
    }
  }

  // ================= CONNECTION =================
  Future<void> _testConnection() async {
    try {
      final connected = await _apiService.checkHealth();
      if (mounted) {
        setState(() => _serverConnected = connected);
        if (connected) {
          _showMessage("✅ Connected to server!");
        } else {
          _showMessage("❌ Server not responding");
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _serverConnected = false);
        _showMessage("❌ Connection failed: ${e.toString()}");
      }
    }
  }

  // ================= FILE SELECTION =================
  Future<void> _selectFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: AppConfig.allowedExtensions
            .map((e) => e.replaceAll('.', ''))
            .toList(),
        withData: false, // More efficient
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.single;

        // Validate file size
        if (file.size > AppConfig.maxFileSizeMB * 1024 * 1024) {
          _showMessage(
            '⚠️ File too large (max ${AppConfig.maxFileSizeMB}MB)',
            isError: true,
          );
          return;
        }

        setState(() => _selectedFile = file);
        AppLogger.info('File selected: ${file.name} (${file.size} bytes)');
      }
    } catch (e, stackTrace) {
      AppLogger.error('File selection failed', e, stackTrace);
      _showMessage('❌ Failed to select file', isError: true);
    }
  }

  // ================= UPLOAD =================
  Future<void> _uploadFile() async {
    if (_selectedFile == null) {
      _showMessage('Please select a file first');
      return;
    }

    if (_isUploading) return;

    if (!_serverConnected) {
      _showMessage('⚠️ Server not connected', isError: true);
      return;
    }

    setState(() {
      _isUploading = true;
      _status = ProcessingStatus(
        stage: 'uploading',
        message: 'Uploading audio...',
        progress: 10,
      );
    });

    try {
      final audioName = await _apiService.uploadAudio(_selectedFile!);

      if (audioName != null && mounted) {
        setState(() {
          _currentFileId = audioName;
          _isUploading = false;
        });
        _showMessage('✅ Upload successful!');
        _startPolling(); // Ensure polling is active
      } else {
        throw Exception('Upload returned null');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _status = null;
        });
        _showMessage('❌ Upload failed: ${e.toString()}', isError: true);
      }
    }
  }

  // ================= STATUS POLLING =================
  void _startPolling() {
    _statusTimer?.cancel();

    _statusTimer = Timer.periodic(AppConfig.statusPollInterval, (_) async {
      await _fetchStatus();
    });

    // Fetch immediately
    _fetchStatus();
  }

  Future<void> _fetchStatus() async {
    // Respect cache duration
    if (_lastStatusFetch != null &&
        DateTime.now().difference(_lastStatusFetch!) <
            AppConfig.statusCacheDuration) {
      return;
    }

    // Don't poll if completed
    if (_status?.isCompleted == true &&
        _status?.file == _currentFileId) {
      _statusTimer?.cancel();
      return;
    }

    try {
      final status = await _apiService.getStatus();

      if (status != null && mounted) {
        setState(() {
          _status = status;
          _lastStatusFetch = DateTime.now();
        });

        // Stop polling on completion or error
        if (status.isCompleted || status.isError) {
          _statusTimer?.cancel();
        }
      }
    } catch (e) {
      // Silently fail status checks to avoid spam
      AppLogger.warning('Status fetch failed: $e');
    }
  }

  // ================= PDF DOWNLOAD =================
  Future<void> _downloadPdf() async {
    if (_currentFileId == null) return;
    if (_isDownloading) return;

    setState(() => _isDownloading = true);

    try {
      final file = await _apiService.downloadPdf(_currentFileId!);

      if (mounted) {
        _showMessage('✅ PDF saved successfully!');
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) {
        _showMessage('❌ Download failed: ${e.toString()}', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  // ================= SERVER SETTINGS =================
  Future<void> _showServerSettings() async {
    final controller = TextEditingController(text: AppConfig.baseUrl);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter server URL:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.24:8000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Tip: Use http://YOUR_IP:8000 for local server or https://... for cloud server',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                AppConfig.baseUrl = url;
                await _saveServerUrl(url);
                _apiService = ApiService(baseUrl: url);
                Navigator.pop(context);
                await _testConnection();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ================= HELPERS =================
  String _getStatusMessage() {
    if (_currentFileId == null) return "Waiting for audio...";
    if (_status == null) return "Connecting...";
    if (_status!.file != _currentFileId) return "Processing previous file...";
    return _status!.message;
  }

  bool get _isCompleted =>
      _status?.isCompleted == true && _status?.file == _currentFileId;

  int _getCurrentStepIndex() {
    if (_status == null) return -1;
    return processSteps.indexWhere((s) => s.key == _status!.stage);
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    final stepIndex = _getCurrentStepIndex();

    return Scaffold(
      appBar: AppBar(
        title: Text(AppConfig.appTitle),
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showServerSettings,
            tooltip: 'Server Settings',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _testConnection();
          await _fetchStatus();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Connection status
              _buildConnectionStatus(),
              const SizedBox(height: 16),

              // File selection
              _buildFileSelection(),
              const SizedBox(height: 16),

              // Processing status
              if (_currentFileId != null) ...[
                _buildProcessingStatus(stepIndex),
                const SizedBox(height: 16),
              ],

              // Download button
              if (_isCompleted) ...[
                _buildDownloadButton(),
                const SizedBox(height: 24),
              ],

              // Info card
              _buildInfoCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _serverConnected ? Colors.green[100] : Colors.red[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _serverConnected ? Colors.green : Colors.red,
          width: 2,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _serverConnected ? Icons.check_circle : Icons.error,
            color: _serverConnected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _serverConnected ? "Server Connected" : "Server Disconnected",
                  style: TextStyle(
                    color: _serverConnected ? Colors.green[900] : Colors.red[900],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  AppConfig.baseUrl,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _testConnection,
            child: const Text("Retry"),
          ),
        ],
      ),
    );
  }

  Widget _buildFileSelection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Select Audio File",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (_selectedFile != null) ...[
              Text(
                _selectedFile!.name,
                style: const TextStyle(fontSize: 13),
              ),
              Text(
                '${(_selectedFile!.size / 1024 / 1024).toStringAsFixed(2)} MB',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ] else
              const Text(
                'No file selected',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isUploading ? null : _selectFile,
                    icon: const Icon(Icons.folder_open),
                    label: const Text("Choose File"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isUploading || _selectedFile == null)
                        ? null
                        : _uploadFile,
                    icon: _isUploading
                        ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : const Icon(Icons.upload),
                    label: Text(_isUploading ? "Uploading..." : "Upload"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingStatus(int stepIndex) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "Processing Status",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_status?.isProcessing == true)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _getStatusMessage(),
              style: TextStyle(
                fontSize: 14,
                color: _status?.isError == true ? Colors.red : null,
              ),
            ),
            if (_status?.file == _currentFileId) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: (_status?.progress ?? 0) / 100,
                backgroundColor: Colors.grey[200],
              ),
              const SizedBox(height: 16),
              ...processSteps.asMap().entries.map((entry) {
                final i = entry.key;
                final step = entry.value;
                final active = i == stepIndex;
                final done = i < stepIndex;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Opacity(
                    opacity: active || done ? 1 : 0.4,
                    child: Row(
                      children: [
                        Text(step.icon, style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            step.label,
                            style: TextStyle(
                              fontWeight: active
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (done)
                          const Icon(
                            Icons.check_circle,
                            size: 18,
                            color: Colors.green,
                          ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadButton() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.all(16),
      ),
      onPressed: _isDownloading ? null : _downloadPdf,
      icon: _isDownloading
          ? const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.white,
        ),
      )
          : const Icon(Icons.download),
      label: Text(
        _isDownloading ? "Downloading..." : "📄 Download Summary PDF",
        style: const TextStyle(fontSize: 16),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  "Bluetooth Upload",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Send audio from your phone via Bluetooth. Windows saves it automatically and processing starts on its own.",
              style: TextStyle(fontSize: 12, color: Colors.blue[900]),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.blue, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Max file size: ${AppConfig.maxFileSizeMB}MB",
                    style: TextStyle(fontSize: 11, color: Colors.blue[800]),
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