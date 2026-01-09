import Flutter
import UIKit
import AVFoundation
import AVKit
import MediaPlayer

public class VideoPlayerPipPlugin: NSObject, FlutterPlugin, AVPictureInPictureControllerDelegate {
    private var channel: FlutterMethodChannel?
    private var pipController: AVPictureInPictureController?
    private var observationToken: NSKeyValueObservation?
    private var isInPipMode: Bool = false
    private var isRestoring: Bool = false
    // Removed unused 'private var playerId' to avoid confusion
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_player_pip", binaryMessenger: registrar.messenger())
        let instance = VideoPlayerPipPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        NSLog("VideoPlayerPip: Plugin registered")
    }
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        NSLog("VideoPlayerPip: Plugin initialized")
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Ensure all Flutter results are sent on the Main Thread
        DispatchQueue.main.async { [weak self] in
            self?.handleMethodCall(call, result: result)
        }
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        NSLog("VideoPlayerPip: Received method call: \(call.method)")
        switch call.method {
        case "isPipSupported":
            result(isPipSupported())
            
        case "enableAutoPip":
            guard let args = call.arguments as? [String: Any],
                  let playerId = args["playerId"] as? Int else { // Note: Flutter sometimes sends Int64, safe casting handles standard Int
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing playerId", details: nil))
                return
            }
            enableAutoPip(playerId: playerId, completion: result)
            
        case "disableAutoPip":
            disableAutoPip(completion: result)
            
        case "enterPipMode":
            guard let args = call.arguments as? [String: Any],
                  let playerId = args["playerId"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing playerId", details: nil))
                return
            }
            enterPipMode(playerId: playerId, completion: result)
            
        case "exitPipMode":
            exitPipMode(completion: result)
            
        case "isInPipMode":
            result(isInPipMode)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func isPipSupported() -> Bool {
        return AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    private func enableAutoPip(playerId: Int, completion: @escaping FlutterResult) {
        guard isPipSupported() else {
            completion(false)
            return
        }
        
        guard let playerLayer = findAVPlayerLayer(playerId: playerId) else {
            NSLog("VideoPlayerPip: Could not find player layer for ID: \(playerId)")
            completion(false)
            return
        }
        
        configureAudioSession()
        
        setupPipController(playerLayer: playerLayer) { success in
            if success {
                NSLog("VideoPlayerPip: Auto PiP enabled successfully")
            }
            completion(success)
        }
    }
    
    private func disableAutoPip(completion: @escaping FlutterResult) {
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            completion(true)
        } else {
            completion(false)
        }
    }
    
    private func enterPipMode(playerId: Int, completion: @escaping FlutterResult) {
        guard isPipSupported() else {
            completion(false)
            return
        }
        
        configureAudioSession()
        
        guard let playerLayer = findAVPlayerLayer(playerId: playerId) else {
            completion(false)
            return
        }
        
        // Ensure player is playing before entering PiP
        if let player = playerLayer.player, player.timeControlStatus != .playing {
            player.play()
        }
        
        // Small delay to ensure layer is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupPipController(playerLayer: playerLayer) { success in
                if success {
                    self?.pipController?.startPictureInPicture()
                }
                completion(success)
            }
        }
    }
    
    private func setupPipController(playerLayer: AVPlayerLayer, completion: @escaping (Bool) -> Void) {
        if #available(iOS 14.0, *) {
            // FIX 1: Don't recreate the controller if it's already set up for this layer
            if let existingController = pipController, existingController.playerLayer == playerLayer {
                NSLog("VideoPlayerPip: Controller already setup for this layer. Updating settings.")
                if #available(iOS 14.2, *) {
                    existingController.canStartPictureInPictureAutomaticallyFromInline = true
                }
                completion(true)
                return
            }
            
            // FIX 2: Only cleanup if we are switching to a NEW layer
            cleanupPipController()
            
            guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
                NSLog("VideoPlayerPip: Failed to init AVPictureInPictureController")
                completion(false)
                return
            }
            
            self.pipController = controller
            controller.delegate = self
            
            if #available(iOS 14.2, *) {
                controller.canStartPictureInPictureAutomaticallyFromInline = true
            }
            
            // Allow skipping ads/seeking
            if #available(iOS 15.0, *) {
                controller.requiresLinearPlayback = false
            }
            
            observationToken = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] (controller, change) in
                guard let self = self, let newValue = change.newValue else { return }
                self.isInPipMode = newValue
                self.channel?.invokeMethod("pipModeChanged", arguments: ["isInPipMode": newValue])
            }
            
            completion(true)
        } else {
            completion(false)
        }
    }
    
    private func cleanupPipController() {
        observationToken?.invalidate()
        observationToken = nil
        
        // FIX 3: Don't stop PiP if we are just cleaning up memory but the user is watching!
        // Only stop if explicitly requested or if the object is deallocating.
        if isInPipMode {
            // Optional: You might want to keep playing in background,
            // but usually if we kill the controller, we should stop PiP.
             pipController?.stopPictureInPicture()
        }
        pipController = nil
    }
    
    private func exitPipMode(completion: @escaping FlutterResult) {
        if isInPipMode, let controller = pipController {
            controller.stopPictureInPicture()
            completion(true)
        } else {
            completion(false)
        }
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("VideoPlayerPip: Audio session error: \(error.localizedDescription)")
        }
        
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Enable Next/Prev
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        
        // Remove existing targets to avoid duplicates
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
         commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            self?.channel?.invokeMethod("pipAction", arguments: ["action": "next"])
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            self?.channel?.invokeMethod("pipAction", arguments: ["action": "previous"])
            return .success
        }
        
        commandCenter.playCommand.addTarget { [weak self] event in
             // Let the player handle play automatically (AVKit usually does), 
             // but we also notify Flutter in case app logic is needed
            self?.channel?.invokeMethod("pipAction", arguments: ["action": "play"])
            
            // If we are controlling the player directly, we might need to play manually
            // self?.pipController?.playerLayer?.player?.play()
             return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] event in
             self?.channel?.invokeMethod("pipAction", arguments: ["action": "pause"])
             // self?.pipController?.playerLayer?.player?.pause()
             return .success
        }
    }

    // MARK: - AVPictureInPictureControllerDelegate
    
    // MARK: - AVPictureInPictureControllerDelegate
    
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isInPipMode = true
        channel?.invokeMethod("pipModeChanged", arguments: ["isInPipMode": true])
    }
    
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isRestoring = false
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isInPipMode = false
        channel?.invokeMethod("pipModeChanged", arguments: ["isInPipMode": false])
        
        if !isRestoring {
             NSLog("VideoPlayerPip: PiP dismissed by user")
             channel?.invokeMethod("pipDismissed", arguments: nil)
        }
        isRestoring = false
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        channel?.invokeMethod("pipError", arguments: ["error": error.localizedDescription])
    }
    
    // FIX 4: Exact signature match for the Restore UI delegate
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        NSLog("VideoPlayerPip: Restore UI requested")
        isRestoring = true
        
        // 1. Tell Flutter to navigate back/render the player
        channel?.invokeMethod("restoreUI", arguments: nil)
        
        // 2. Wait a split second for Flutter to actually mount the view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            completionHandler(true)
        }
    }

    // MARK: - View Search Logic
    
    private func findAVPlayerLayer(playerId: Int) -> AVPlayerLayer? {
        // Modern iOS 13+ Scene Search
        let keyWindow = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first(where: { $0.isKeyWindow })
            
        guard let rootViewController = keyWindow?.rootViewController else { return nil }
        return findAVPlayerLayerInView(rootViewController.view)
    }

    private func findAVPlayerLayerInView(_ view: UIView) -> AVPlayerLayer? {
        if let playerLayer = view.layer as? AVPlayerLayer {
            // Validation: Ensure this layer actually has a player
            if playerLayer.player != nil { return playerLayer }
        }
        
        // Common Flutter Video Player wrapper check
        if let sublayers = view.layer.sublayers {
            for sublayer in sublayers {
                if let playerLayer = sublayer as? AVPlayerLayer, playerLayer.player != nil {
                    return playerLayer
                }
            }
        }
        
        for subview in view.subviews {
            if let layer = findAVPlayerLayerInView(subview) {
                return layer
            }
        }
        return nil
    }
    
    deinit {
        cleanupPipController()
    }
}


//import Flutter
//import UIKit
//import AVFoundation
//import AVKit
//
//public class VideoPlayerPipPlugin: NSObject, FlutterPlugin, AVPictureInPictureControllerDelegate {
//  private var channel: FlutterMethodChannel?
//  private var pipController: AVPictureInPictureController?
//  private var observationToken: NSKeyValueObservation?
//  private var isInPipMode: Bool = false
//    private var playerId: String? = nil
//    
//  
//  public static func register(with registrar: FlutterPluginRegistrar) {
//    let channel = FlutterMethodChannel(name: "video_player_pip", binaryMessenger: registrar.messenger())
//    let instance = VideoPlayerPipPlugin(channel: channel)
//    registrar.addMethodCallDelegate(instance, channel: channel)
//    NSLog("VideoPlayerPip: Plugin registered")
//  }
//  
//  init(channel: FlutterMethodChannel) {
//    self.channel = channel
//    super.init()
//    NSLog("VideoPlayerPip: Plugin initialized")
//  }
//
//  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
//    NSLog("VideoPlayerPip: Received method call: \(call.method)")
//    switch call.method {
//    case "isPipSupported":
//      let supported = isPipSupported()
//      NSLog("VideoPlayerPip: isPipSupported = \(supported)")
//      result(supported)
//      
//    case "enableAutoPip":
//      guard let args = call.arguments as? [String: Any],
//            let playerId = args["playerId"] as? Int else {
//        NSLog("VideoPlayerPip: enableAutoPip failed - Invalid arguments")
//        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing playerId", details: nil))
//        return
//      }
//      
//      NSLog("VideoPlayerPip: Attempting to enable Auto PiP for playerId: \(playerId)")
//      enableAutoPip(playerId: playerId, completion: result)
//
//    case "enterPipMode":
//      guard let args = call.arguments as? [String: Any],
//            let playerId = args["playerId"] as? Int else {
//        NSLog("VideoPlayerPip: enterPipMode failed - Invalid arguments")
//        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing playerId", details: nil))
//        return
//      }
//      
//      NSLog("VideoPlayerPip: Attempting to enter PiP mode for playerId: \(playerId)")
//      enterPipMode(playerId: playerId, completion: result)
//      
//    case "exitPipMode":
//      NSLog("VideoPlayerPip: Attempting to exit PiP mode, current isInPipMode = \(isInPipMode), pipController exists: \(pipController != nil)")
//      exitPipMode(completion: result)
//      
//    case "isInPipMode":
//      NSLog("VideoPlayerPip: isInPipMode query = \(isInPipMode)")
//      result(isInPipMode)
//      
//    default:
//      NSLog("VideoPlayerPip: Method not implemented: \(call.method)")
//      result(FlutterMethodNotImplemented)
//    }
//  }
//  
//  private func isPipSupported() -> Bool {
//    if #available(iOS 14.0, *) {
//      let supported = AVPictureInPictureController.isPictureInPictureSupported()
//      NSLog("VideoPlayerPip: PiP supported by system: \(supported)")
//      return supported
//    }
//    NSLog("VideoPlayerPip: PiP not supported (iOS < 14.0)")
//    return false
//  }
//
//  private func enableAutoPip(playerId: Int, completion: @escaping FlutterResult) {
//      NSLog("VideoPlayerPip: enableAutoPip called for playerId: \(playerId)")
//      if !isPipSupported() {
//        NSLog("VideoPlayerPip: PiP not supported by the device")
//        completion(false)
//        return
//      }
//      
//      // Find the AVPlayerLayer
//      guard let playerLayer = findAVPlayerLayer(playerId: playerId) else {
//        NSLog("VideoPlayerPip: Could not find player layer for ID: \(playerId)")
//        completion(false)
//        return
//      }
//      
//      // Configure audio session for background playback
//      configureAudioSession()
//
//      // Setup the controller but do NOT start it immediately
//      setupPipController(playerLayer: playerLayer) { [weak self] success in
//          if success {
//              NSLog("VideoPlayerPip: Auto PiP enabled successfully")
//          } else {
//              NSLog("VideoPlayerPip: Failed to enable Auto PiP")
//          }
//          completion(success)
//      }
//  }
//  
//  private func enterPipMode(playerId: Int, completion: @escaping FlutterResult) {
//    NSLog("VideoPlayerPip: enterPipMode called for playerId: \(playerId)")
//    if !isPipSupported() {
//      NSLog("VideoPlayerPip: PiP not supported by the device")
//      completion(false)
//      return
//    }
//    
//    // Configure audio session for background playback
//    configureAudioSession()
//
//    // Find the AVPlayerLayer
//    NSLog("VideoPlayerPip: Searching for AVPlayerLayer for playerId: \(playerId)")
//    guard let playerLayer = findAVPlayerLayer(playerId: playerId) else {
//      NSLog("VideoPlayerPip: Could not find player layer for ID: \(playerId)")
//      completion(false)
//      return
//    }
//    
//    NSLog("VideoPlayerPip: Found AVPlayerLayer: \(playerLayer)")
//    
//    // Check if player is ready
//    if let player = playerLayer.player {
//      NSLog("VideoPlayerPip: Player status: \(player.status.rawValue), currentItem: \(player.currentItem != nil ? "exists" : "nil"), error: \(player.error?.localizedDescription ?? "none")")
//      
//      // Ensure the player is playing
//      if player.timeControlStatus != .playing {
//        NSLog("VideoPlayerPip: Player is not currently playing, trying to play")
//        player.play()
//      }
//      
//      // Wait a moment to ensure player is properly prepared
//      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
//        self?.setupPipController(playerLayer: playerLayer) { success in
//            if success {
//                self?.startPipAfterSetup()
//            }
//            completion(success)
//        }
//      }
//    } else {
//      NSLog("VideoPlayerPip: AVPlayerLayer has no player set")
//      completion(false)
//    }
//  }
//
//  /// Configures the PiP controller without starting it
//  private func setupPipController(playerLayer: AVPlayerLayer, completion: @escaping (Bool) -> Void) {
//    if #available(iOS 14.0, *) {
//      // Check if we can create a PiP controller with this layer
//      if AVPictureInPictureController.isPictureInPictureSupported() && playerLayer.player != nil {
//        
//        // If we already have a controller for this layer, we might not need to recreate it,
//        // but for safety/consistency with previous logic, let's refresh it or check it.
//        // For this implementation, we'll recreate to be safe, but we must be careful about observing.
//        
//        cleanupPipController()
//        
//        pipController = AVPictureInPictureController(playerLayer: playerLayer)
//        pipController?.delegate = self
//        
//        // Enable PiP to start from inline (foreground) - This is CRITICAL for Auto PiP
//        if #available(iOS 14.2, *) {
//          NSLog("VideoPlayerPip: Setting canStartPictureInPictureAutomaticallyFromInline to true")
//          pipController?.canStartPictureInPictureAutomaticallyFromInline = true
//        } else {
//             NSLog("VideoPlayerPip: iOS < 14.2, Auto PiP not supported")
//        }
//        
//        // Allow PiP during interactive playback
//        if #available(iOS 15.0, *) {
//          pipController?.requiresLinearPlayback = false
//        }
//        
//        // Set up observation for the possible PiP state
//        observationToken = pipController?.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] (controller, change) in
//            guard let self = self, let newValue = change.newValue else { return }
//            NSLog("VideoPlayerPip: isPictureInPictureActive changed to \(newValue)")
//            self.isInPipMode = newValue
//            self.channel?.invokeMethod("pipModeChanged", arguments: ["isInPipMode": newValue])
//        }
//
//        completion(true)
//      } else {
//        NSLog("VideoPlayerPip: Cannot create PiP controller - either not supported or player is nil")
//        completion(false)
//      }
//    } else {
//        completion(false)
//    }
//  }
//  
//  private func startPipAfterSetup() {
//      // Start PiP - Try to start it more forcefully
//      NSLog("VideoPlayerPip: Attempting to start PiP")
//      
//      if #available(iOS 15.0, *) {
//        // On iOS 15+, we can try a slightly more direct approach
//        pipController?.startPictureInPicture()
//        
//        // Also try after a short delay as a fallback
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
//          guard let self = self, !(self.pipController?.isPictureInPictureActive ?? false) else { return }
//          NSLog("VideoPlayerPip: Trying to start PiP again after delay (iOS 15+)")
//          self.pipController?.startPictureInPicture()
//        }
//        
//      } else {
//        // On iOS 14, just use the regular API
//        pipController?.startPictureInPicture()
//      }
//  }
//  
//  private func cleanupPipController() {
//    observationToken?.invalidate()
//    observationToken = nil
//    
//    if isInPipMode && pipController != nil {
//      pipController?.stopPictureInPicture()
//    }
//    
//    pipController = nil
//  }
//  
//  private func exitPipMode(completion: @escaping FlutterResult) {
//    NSLog("VideoPlayerPip: exitPipMode called, isInPipMode: \(isInPipMode), pipController: \(String(describing: pipController))")
//    if isInPipMode, pipController != nil {
//      NSLog("VideoPlayerPip: Stopping picture-in-picture")
//      pipController?.stopPictureInPicture()
//      completion(true)
//    } else {
//      NSLog("VideoPlayerPip: Cannot stop PiP - either not in PiP mode or controller is nil")
//      completion(false)
//    }
//  }
//  
//  private func configureAudioSession() {
//    let session = AVAudioSession.sharedInstance()
//    do {
//      try session.setCategory(.playback, mode: .moviePlayback)
//      try session.setActive(true)
//      NSLog("VideoPlayerPip: Audio session configured for playback and active")
//    } catch {
//      NSLog("VideoPlayerPip: Failed to configure audio session: \(error.localizedDescription)")
//    }
//  }
//
//  /**
//   * Find the AVPlayerLayer for the specified player ID.
//   * This searches through the view hierarchy to find the platform view created by video_player.
//   */
//  private func findAVPlayerLayer(playerId: Int) -> AVPlayerLayer? {
//    NSLog("VideoPlayerPip: Finding AVPlayerLayer for playerId: \(playerId)")
//    // Use a more modern approach to get the active window
//    let keyWindow = getKeyWindow()
//    NSLog("VideoPlayerPip: keyWindow found: \(keyWindow != nil)")
//    if let rootViewController = keyWindow?.rootViewController {
//      NSLog("VideoPlayerPip: Starting search from rootViewController: \(type(of: rootViewController))")
//      // Start with the root view and search recursively
//      return findAVPlayerLayerInView(rootViewController.view, depth: 0)
//    }
//    NSLog("VideoPlayerPip: No rootViewController found")
//    return nil
//  }
//  
//  /**
//   * Get the key window using a more modern approach that works on iOS 13+
//   */
//  private func getKeyWindow() -> UIWindow? {
//    if #available(iOS 13.0, *) {
//      let scenes = UIApplication.shared.connectedScenes
//        .filter { $0.activationState == .foregroundActive }
//        .compactMap { $0 as? UIWindowScene }
//      
//      NSLog("VideoPlayerPip: Found \(scenes.count) active window scenes")
//      
//      if let windowScene = scenes.first {
//        let windows = windowScene.windows.filter { $0.isKeyWindow }
//        NSLog("VideoPlayerPip: Found \(windows.count) key windows in the first scene")
//        return windows.first
//      }
//      return nil
//    } else {
//      let window = UIApplication.shared.keyWindow
//      NSLog("VideoPlayerPip: Using legacy keyWindow approach: \(window != nil)")
//      return window
//    }
//  }
//  
//  /**
//   * Recursively search for an AVPlayerLayer in the view hierarchy.
//   */
//  private func findAVPlayerLayerInView(_ view: UIView, depth: Int) -> AVPlayerLayer? {
//    let indentation = String(repeating: "  ", count: depth)
//    let className = NSStringFromClass(type(of: view))
//    NSLog("\(indentation)VideoPlayerPip: Checking view: \(className)")
//    
//    // Check if this view's layer is an AVPlayerLayer
//    if let playerLayer = view.layer as? AVPlayerLayer {
//      NSLog("\(indentation)VideoPlayerPip: Found AVPlayerLayer directly as view's layer")
//      // Check if the player is set
//      if let player = playerLayer.player {
//        NSLog("\(indentation)VideoPlayerPip: AVPlayerLayer has player: \(player)")
//        return playerLayer
//      } else {
//        NSLog("\(indentation)VideoPlayerPip: AVPlayerLayer has no player set")
//      }
//    }
//    
//    // Check for class name matching FVPPlayerView which has an AVPlayerLayer as its layer
//    if className.contains("FVPPlayerView") {
//      NSLog("\(indentation)VideoPlayerPip: Found FVPPlayerView")
//      if let playerLayer = view.layer as? AVPlayerLayer {
//        NSLog("\(indentation)VideoPlayerPip: FVPPlayerView's layer is AVPlayerLayer")
//        if let player = playerLayer.player {
//          NSLog("\(indentation)VideoPlayerPip: FVPPlayerView's AVPlayerLayer has player: \(player)")
//        } else {
//          NSLog("\(indentation)VideoPlayerPip: FVPPlayerView's AVPlayerLayer has no player set")
//        }
//        return playerLayer
//      } else {
//        NSLog("\(indentation)VideoPlayerPip: FVPPlayerView's layer is not AVPlayerLayer: \(type(of: view.layer))")
//      }
//    }
//    
//    // Check sublayers directly in case AVPlayerLayer is a sublayer
//    if let sublayers = view.layer.sublayers {
//      NSLog("\(indentation)VideoPlayerPip: Checking \(sublayers.count) sublayers")
//      for sublayer in sublayers {
//        if let playerLayer = sublayer as? AVPlayerLayer {
//          NSLog("\(indentation)VideoPlayerPip: Found AVPlayerLayer as a sublayer")
//          if let player = playerLayer.player {
//            NSLog("\(indentation)VideoPlayerPip: Sublayer AVPlayerLayer has player: \(player)")
//            return playerLayer
//          } else {
//            NSLog("\(indentation)VideoPlayerPip: Sublayer AVPlayerLayer has no player set")
//          }
//        }
//      }
//    }
//    
//    // Recursively check subviews
//    NSLog("\(indentation)VideoPlayerPip: Checking \(view.subviews.count) subviews")
//    for subview in view.subviews {
//      if let layer = findAVPlayerLayerInView(subview, depth: depth + 1) {
//        return layer
//      }
//    }
//    
//    return nil
//  }
//  
//  // MARK: - AVPictureInPictureControllerDelegate
//  
//  public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//    NSLog("VideoPlayerPip: PiP started successfully")
//    isInPipMode = true
//    channel?.invokeMethod("pipModeChanged", arguments: ["isInPipMode": true])
//  }
//  
//  public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//    NSLog("VideoPlayerPip: PiP stopped")
//    isInPipMode = false
//    channel?.invokeMethod("pipModeChanged", arguments: ["isInPipMode": false])
//    // Explicitly release the controller when PiP is stopped
//    if #available(iOS 14.0, *) {
//        if self.pipController == pictureInPictureController {
//            NSLog("VideoPlayerPip: Releasing pipController reference")
//            self.pipController = nil
//        } else {
//            NSLog("VideoPlayerPip: Stopped PiP controller doesn't match current pipController")
//        }
//    } else {
//        if self.pipController === pictureInPictureController {
//            NSLog("VideoPlayerPip: Releasing pipController reference (using identity check)")
//            self.pipController = nil
//        } else {
//            NSLog("VideoPlayerPip: Stopped PiP controller doesn't match current pipController (using identity check)")
//        }
//    }
//  }
//  
//  public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
//    NSLog("VideoPlayerPip: Failed to start PiP: \(error.localizedDescription)")
//    NSLog("VideoPlayerPip: Error details: \(error)")
//    channel?.invokeMethod("pipError", arguments: ["error": error.localizedDescription])
//  }
//  
//  public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//    NSLog("VideoPlayerPip: PiP will start")
//  }
//  
//  public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
//    NSLog("VideoPlayerPip: PiP will stop")
//  }
//    
//public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
//    NSLog("VideoPlayerPip: interface")
//    channel?.invokeMethod("restoreUI", arguments: nil)
//    completionHandler(true)
//    
//    }
//
//  deinit {
//    NSLog("VideoPlayerPip: Plugin being deallocated")
//    cleanupPipController()
//  }
//}


