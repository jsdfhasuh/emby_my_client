import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:emby_my_client/playback/preview/media_kit_frame_probe.dart';

const _sampleUri =
    'https://media.w3.org/2010/05/sintel/trailer.mp4';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MediaKitFrameProbeApp());
}

class MediaKitFrameProbeApp extends StatelessWidget {
  const MediaKitFrameProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'media_kit frame probe',
      theme: ThemeData(useMaterial3: true),
      home: const MediaKitFrameProbePage(),
    );
  }
}

class MediaKitFrameProbePage extends StatefulWidget {
  const MediaKitFrameProbePage({super.key});

  @override
  State<MediaKitFrameProbePage> createState() => _MediaKitFrameProbePageState();
}

class _MediaKitFrameProbePageState extends State<MediaKitFrameProbePage> {
  late final MediaKitFrameProbe _probe;
  late final TextEditingController _uriController;
  late final TextEditingController _targetController;
  VideoController? _videoController;
  MediaKitFrameProbeResult? _result;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _probe = MediaKitFrameProbe(
      onVideoControllerCreated: (controller) {
        if (!mounted) return;
        setState(() => _videoController = controller);
      },
    );
    _uriController = TextEditingController(text: _sampleUri);
    _targetController = TextEditingController(text: '10');
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    _uriController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final uri = _uriController.text.trim();
    if (uri.isEmpty) return;
    setState(() {
      _running = true;
      _result = null;
    });

    final targetSeconds = int.tryParse(_targetController.text.trim()) ?? 10;
    final result = await _probe.capture(
      uri: uri,
      target: Duration(seconds: targetSeconds < 0 ? 0 : targetSeconds),
    );
    debugPrint('phase0_probe_result=${result.toSafeMap()}');
    if (!mounted) return;
    setState(() {
      _videoController = null;
      _running = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final videoController = _videoController;
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 0 media_kit probe')),
      body: Stack(
        children: <Widget>[
          ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              TextField(
                controller: _uriController,
                decoration: const InputDecoration(labelText: 'Media URI'),
              ),
              TextField(
                controller: _targetController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Target seconds'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _running ? null : _run,
                child: Text(_running ? 'Running...' : 'Capture frame'),
              ),
              if (result != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(result.toSafeMap().toString()),
                if (result.imageBytes != null && result.format != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Image.memory(result.imageBytes!),
                  ),
              ],
            ],
          ),
          if (videoController != null)
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: Video(
                controller: videoController,
                controls: NoVideoControls,
                wakelock: false,
              ),
            ),
        ],
      ),
    );
  }
}
