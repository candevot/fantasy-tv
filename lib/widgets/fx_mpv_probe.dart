import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// media_kit 依赖探针：把传入的 [url] 交给 libmpv 播放。
///
/// 仅用于验证 `media_kit` / `media_kit_video` / `media_kit_libs_video`
/// 在当前工程里可用，暂不接入任何页面；播放主链路仍走 FxPlayer。
class FxMpvProbe extends StatefulWidget {
  const FxMpvProbe({super.key, required this.url});

  /// 视频地址（m3u8 / mp4 均可）。
  final String url;

  @override
  State<FxMpvProbe> createState() => _FxMpvProbeState();
}

class _FxMpvProbeState extends State<FxMpvProbe> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<String>? _errorSub;
  String? _error;

  @override
  void initState() {
    super.initState();
    _errorSub = _player.stream.error.listen((message) {
      if (mounted) setState(() => _error = message);
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.url));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: _controller, controls: NoVideoControls),
          if (_error != null)
            ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
