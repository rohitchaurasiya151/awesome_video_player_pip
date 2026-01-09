import 'dart:async';
import 'dart:io';

import 'package:awesome_video_player_pip/index.dart';
import 'package:flutter/material.dart';

void main(List<String> args) {
  print("App Started");
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Player PiP Example',
      builder: (context, child) {
        return Stack(children: [if (child != null) child, const GlobalPlayerOverlay()]);
      },
      home: const HomeScreen(),
    );
  }
}

// --- Player Manager (Singleton State) ---
class PlayerManager extends ChangeNotifier {
  static final PlayerManager instance = PlayerManager._();
  PlayerManager._();

  VideoPlayerController? controller;
  bool isPlayerOpen = false;
  bool isMinimized = false;

  void playVideo(String url) {
    // Determine options based on platform/needs.
    // mixWithOthers: false ensures we take audio focus for Auto PiP.
    final options = VideoPlayerOptions(allowBackgroundPlayback: true);

    // Dispose previous if exists
    controller?.dispose();
    controller = null;
    isPlayerOpen = true;
    isMinimized = false;
    notifyListeners();

    controller = VideoPlayerController.networkUrl(Uri.parse(url), videoPlayerOptions: options)
      ..initialize().then((_) {
        controller!.play();
        notifyListeners(); // Update UI with initialized controller

        // Enable Auto PiP once initialized
        Future.delayed(const Duration(seconds: 1), () {
          if (controller != null) {
            VideoPlayerPip.enableAutoPip(
              controller!,
              width: controller!.value.size.width.toInt(),
              height: controller!.value.size.height.toInt(),
            );
          }
        });
      });
  }

  void closePlayer() {
    controller?.dispose();
    controller = null;
    // Fix: Ensure we reset flags after disposing
    isPlayerOpen = false;
    isMinimized = false;
    VideoPlayerPip.disableAutoPip(); // Disable Auto PiP when closed
    notifyListeners();
  }

  void minimize() async {
    if (Platform.isAndroid) {
      isMinimized = true;
    } else if (Platform.isIOS) {
      if (controller != null) {
        final ratio = controller!.value.aspectRatio;
        await VideoPlayerPip.enterPipMode(controller!, width: 300, height: (300 / ratio).toInt());
        Future.delayed(const Duration(seconds: 1), () {
          isMinimized = true;
          notifyListeners();
        });
      }
    }
    notifyListeners();
  }

  void maximize() {
    isMinimized = false;
    notifyListeners();
  }

  void togglePlayPause() {
    if (controller != null && controller!.value.isInitialized) {
      if (controller!.value.isPlaying) {
        controller!.pause();
        VideoPlayerPip.disableAutoPip(); // Disable Auto PiP when paused
      } else {
        controller!.play();
        // Enable Auto PiP when playing
        VideoPlayerPip.enableAutoPip(
          controller!,
          width: controller!.value.size.width.toInt(),
          height: controller!.value.size.height.toInt(),
        );
      }
      notifyListeners();
    }
  }
}

// --- Global Overlay Widget ---
class GlobalPlayerOverlay extends StatefulWidget {
  const GlobalPlayerOverlay({super.key});

  @override
  State<GlobalPlayerOverlay> createState() => _GlobalPlayerOverlayState();
}

class _GlobalPlayerOverlayState extends State<GlobalPlayerOverlay> with WidgetsBindingObserver {
  // Draggable position state
  double _bottom = 100.0;
  double _right = 20.0;
  double _playerWidth = 200.0; // Dynamic width state
  bool _isInPipMode = false;
  StreamSubscription<bool>? _pipSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PlayerManager.instance.addListener(_onPlayerStateChange);

    _pipSubscription = VideoPlayerPip.instance.onPipModeChanged.listen((isInPipMode) {
      if (mounted) {
        setState(() {
          _isInPipMode = isInPipMode;
        });
      }
    });

    VideoPlayerPip.instance.onPipDismissed.listen((_) {
      print("PiP dismissed by user. Closing player...");
      PlayerManager.instance.closePlayer();
    });

    VideoPlayerPip.instance.onPipAction.listen((action) {
      final manager = PlayerManager.instance;
      switch (action) {
        case 'play':
          manager.controller?.play();
          break;
        case 'pause':
          manager.controller?.pause();
          break;
        case 'next':
          print("Next video requested");
          break;
        case 'previous':
          print("Previous video requested");
          break;
      }
    });
  }

  bool _wasPlaying = false;
  void _onPlayerStateChange() {
    if (mounted) setState(() {});

    // Sync state with native (Android MediaSession)
    final manager = PlayerManager.instance;
    if (manager.controller != null && manager.controller!.value.isInitialized) {
      final isPlaying = manager.controller!.value.isPlaying;
      if (isPlaying != _wasPlaying) {
        _wasPlaying = isPlaying;
        VideoPlayerPip.instance.updateBackgroundPlaybackState(isPlaying: isPlaying);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PlayerManager.instance.removeListener(_onPlayerStateChange);
    _pipSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final manager = PlayerManager.instance;
    if (manager.controller == null || !manager.controller!.value.isInitialized) return;

    if (state == AppLifecycleState.resumed) {
      // Stop PiP on resume if needed, or sync state
      // VideoPlayerPip.exitPipMode();
    } else if (state == AppLifecycleState.inactive) {
      if (Platform.isAndroid && manager.controller!.value.isPlaying) {
        // Android requires entering PiP in onPause (inactive), not onStop (paused)
        final ratio = manager.controller!.value.aspectRatio;
        VideoPlayerPip.enterPipMode(manager.controller!, width: 300, height: (300 / ratio).toInt());
      }
    } else if (state == AppLifecycleState.paused) {
      if (Platform.isIOS && manager.controller!.value.isPlaying) {
        final ratio = manager.controller!.value.aspectRatio;
        VideoPlayerPip.enterPipMode(manager.controller!, width: 300, height: (300 / ratio).toInt());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    print("manager.isMinimized ${manager.isMinimized}");

    // If native PiP is active, use the overlay to show ONLY the video.
    // This allows the Android PiP window (which shows the Activity) to display just the video.
    if (_isInPipMode && Platform.isAndroid) {
      return ValueListenableBuilder(
        valueListenable: manager.controller!,
        builder: (context, value, child) {
          return SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: value.size.width,
                height: value.size.height,
                child: VideoPlayer(manager.controller!),
              ),
            ),
          );
        },
      );
    }

    if (!manager.isPlayerOpen || manager.controller == null) {
      return const SizedBox.shrink();
    }

    if (Platform.isIOS && manager.isMinimized) {
      return const SizedBox.shrink();
    }

    // Wrap in Material/Overlay support
    return manager.isMinimized ? _buildMiniPlayer(manager) : _buildFullScreenPlayer(manager);
  }

  Widget _buildMiniPlayer(PlayerManager manager) {
    final double aspectRatio = manager.controller!.value.aspectRatio;
    final double height = _playerWidth / aspectRatio;

    return Positioned(
      bottom: _bottom,
      right: _right,
      width: _playerWidth,
      height: height,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _bottom -= details.delta.dy;
            _right -= details.delta.dx;
          });
        },
        onTap: manager.maximize,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _playerWidth,
                  height: height,
                  child: VideoPlayer(manager.controller!),
                ),
              ),
              // Play/Pause Button
              Center(
                child: IconButton(
                  onPressed: manager.togglePlayPause,
                  icon: Icon(
                    manager.controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
              // Close Button
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: manager.closePlayer,
                  child: Container(
                    color: Colors.black26,
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.close, color: Colors.white, size: 16),
                  ),
                ),
              ),
              // Resize Handle (Top-Left)
              Positioned(
                top: 0,
                left: 0,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      // increasing width expands to the left (since we are anchored right)
                      // Dragging LEFT (negative dx) should INCREASE width
                      _playerWidth -= details.delta.dx;

                      // Clamp width
                      if (_playerWidth < 100) _playerWidth = 100;
                      if (_playerWidth > MediaQuery.of(context).size.width - 20) {
                        _playerWidth = MediaQuery.of(context).size.width - 20;
                      }
                    });
                  },
                  child: Container(
                    color: Colors.black26,
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.open_with, color: Colors.white, size: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullScreenPlayer(PlayerManager manager) {
    return Positioned.fill(
      child: Material(
        // Required for Scaffold etc
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: const Text("Playing", style: TextStyle(color: Colors.white)),
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down), // Minimize icon
              onPressed: manager.minimize,
            ),
            actions: [IconButton(icon: const Icon(Icons.close), onPressed: manager.closePlayer)],
          ),
          body: Stack(
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: manager.controller!.value.aspectRatio,
                  child: VideoPlayer(manager.controller!),
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: manager.togglePlayPause,
                  icon: Icon(
                    manager.controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 50,
                    color: Colors.white,
                  ),
                ),
              ),
              Positioned(
                bottom: 20,
                right: 20,
                child: FloatingActionButton(
                  onPressed: () {
                    // Manual Trigger for System PiP
                    final ratio = manager.controller!.value.aspectRatio;
                    VideoPlayerPip.enterPipMode(
                      manager.controller!,
                      width: 300,
                      height: (300 / ratio).toInt(),
                    );
                  },
                  child: const Icon(Icons.picture_in_picture),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Home Screen ---
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Card(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.network(
                'https://i1.sndcdn.com/artworks-000005011281-9brqv2-t1080x1080.jpg',
                width: 300,
                height: 300,
              ),
              const Text('Big Buck Bunny'),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => PlayerManager.instance.playVideo(
                  'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
                ),
                child: const Text('Play'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  // Navigation Test
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SecondScreen()));
                },
                child: const Text('Go to Second Screen'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SecondScreen extends StatelessWidget {
  const SecondScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Second Screen')),
      body: const Center(child: Text('The player should persist here!')),
    );
  }
}
