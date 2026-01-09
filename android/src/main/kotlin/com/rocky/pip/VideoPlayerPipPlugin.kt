package com.rocky.pip

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.util.Log
import android.util.Rational
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

class VideoPlayerPipPlugin: FlutterPlugin, MethodCallHandler, ActivityAware {
    private val TAG = "VideoPlayerPipPlugin"
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var isInPipMode = false
    private var activityBinding: ActivityPluginBinding? = null
    private var componentCallback: android.content.ComponentCallbacks? = null
    
    // Track the active player ID for automatic triggers
    private var activePlayerId: Int? = null

    // Listener for Home Button on Android 11 and below
    private val userLeaveHintListener = PluginRegistry.UserLeaveHintListener {
        if (activePlayerId != null && !isInPipMode) {
            Log.d(TAG, "Home button pressed: Triggering PiP")
            enterPipMode(activePlayerId!!, null, null)
        }
    }

    // --- FlutterPlugin Interface ---

    private var mediaSession: android.support.v4.media.session.MediaSessionCompat? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "video_player_pip")
        channel.setMethodCallHandler(this)
        
        // Initialize MediaSession
        mediaSession = android.support.v4.media.session.MediaSessionCompat(flutterPluginBinding.applicationContext, TAG)
        mediaSession?.setCallback(object : android.support.v4.media.session.MediaSessionCompat.Callback() {
            override fun onPlay() {
                channel.invokeMethod("pipAction", mapOf("action" to "play"))
            }

            override fun onPause() {
                channel.invokeMethod("pipAction", mapOf("action" to "pause"))
            }
            
            override fun onSkipToNext() {
                channel.invokeMethod("pipAction", mapOf("action" to "next"))
            }

            override fun onSkipToPrevious() {
                channel.invokeMethod("pipAction", mapOf("action" to "previous"))
            }
        })
        mediaSession?.isActive = true
        
        // Set initial playback state
        updatePlaybackState(android.support.v4.media.session.PlaybackStateCompat.STATE_PLAYING)
    }
    
    // Helper to update playback state
    private fun updatePlaybackState(state: Int) {
        val actions = android.support.v4.media.session.PlaybackStateCompat.ACTION_PLAY or
                      android.support.v4.media.session.PlaybackStateCompat.ACTION_PAUSE or
                      android.support.v4.media.session.PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                      android.support.v4.media.session.PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                      android.support.v4.media.session.PlaybackStateCompat.ACTION_PLAY_PAUSE

        val speed = if (state == android.support.v4.media.session.PlaybackStateCompat.STATE_PLAYING) 1.0f else 0.0f
        
        val playbackState = android.support.v4.media.session.PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(state, android.support.v4.media.session.PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN, speed)
            .build()
            
        mediaSession?.setPlaybackState(playbackState)
        
        if (!mediaSession!!.isActive) {
            mediaSession?.isActive = true
        }

        // Show/Update Notification
        if (state == android.support.v4.media.session.PlaybackStateCompat.STATE_PLAYING || 
            state == android.support.v4.media.session.PlaybackStateCompat.STATE_PAUSED) {
            showNotification(state)
        } else {
            cancelNotification()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                "media_control",
                "Media Controls",
                android.app.NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Media controls for video player"
            channel.setShowBadge(false)
            channel.lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            val manager = activity?.getSystemService(android.app.NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    // Start with default metadata
    private var currentTitle: String = "Video Player"
    private var currentArtist: String = "Playing Video"
    
    private fun updateMediaMetadata(title: String?, artist: String?) {
        currentTitle = title ?: "Video Player"
        currentArtist = artist ?: "Playing Video"
        
        val metadataBuilder = android.support.v4.media.MediaMetadataCompat.Builder()
        
        metadataBuilder.putString(android.support.v4.media.MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
        metadataBuilder.putString(android.support.v4.media.MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
        metadataBuilder.putString(android.support.v4.media.MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, currentTitle)
        metadataBuilder.putString(android.support.v4.media.MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, currentArtist)
        // Note: For Album Art, we would need to load a Bitmap. For now, we skip it or use a default resource if available.
        
        mediaSession?.setMetadata(metadataBuilder.build())
        
        // If notification is visible, update it
        val state = mediaSession?.controller?.playbackState?.state ?: android.support.v4.media.session.PlaybackStateCompat.STATE_NONE
        if (state == android.support.v4.media.session.PlaybackStateCompat.STATE_PLAYING || 
            state == android.support.v4.media.session.PlaybackStateCompat.STATE_PAUSED) {
            showNotification(state)
        }
    }

    private fun showNotification(state: Int) {
        if (activity == null) return
        createNotificationChannel()

        val isPlaying = state == android.support.v4.media.session.PlaybackStateCompat.STATE_PLAYING
        
        // Action: Previous
        val prevIntent = android.content.Intent("com.rocky.pip.ACTION_PREVIOUS").setPackage(activity!!.packageName)
        val prevPendingIntent = android.app.PendingIntent.getBroadcast(
            activity, 0, prevIntent, android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
        )
        val prevAction = androidx.core.app.NotificationCompat.Action(
            android.R.drawable.ic_media_previous, "Previous", prevPendingIntent
        )

        // Action: Play/Pause
        val playPauseIntent = android.content.Intent(if (isPlaying) "com.rocky.pip.ACTION_PAUSE" else "com.rocky.pip.ACTION_PLAY").setPackage(activity!!.packageName)
        val playPausePendingIntent = android.app.PendingIntent.getBroadcast(
            activity, 1, playPauseIntent, android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
        )
        val playPauseAction = androidx.core.app.NotificationCompat.Action(
            if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (isPlaying) "Pause" else "Play",
            playPausePendingIntent
        )
        
        // Action: Next
        val nextIntent = android.content.Intent("com.rocky.pip.ACTION_NEXT").setPackage(activity!!.packageName)
        val nextPendingIntent = android.app.PendingIntent.getBroadcast(
            activity, 2, nextIntent, android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
        )
        val nextAction = androidx.core.app.NotificationCompat.Action(
            android.R.drawable.ic_media_next, "Next", nextPendingIntent
        )

        val builder = androidx.core.app.NotificationCompat.Builder(activity!!, "media_control")
            .setStyle(androidx.media.app.NotificationCompat.MediaStyle()
                .setMediaSession(mediaSession?.sessionToken)
                .setShowActionsInCompactView(0, 1, 2)) // Indexes of actions to show (Prev, Play/Pause, Next)
            .setSmallIcon(android.R.drawable.ic_media_play) // Fallback icon, app should provide one
            .setVisibility(androidx.core.app.NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_LOW) // Low priority to avoid sound/vibration
            .setOnlyAlertOnce(true)
            .setContentTitle(currentTitle) // Use current title
            .setContentText(currentArtist)  // Use current artist/subtitle
            .addAction(prevAction)
            .addAction(playPauseAction)
            .addAction(nextAction)
            
        val notificationManager = androidx.core.app.NotificationManagerCompat.from(activity!!)
        try {
            notificationManager.notify(1, builder.build())
        } catch (e: SecurityException) {
            // Handle missing POST_NOTIFICATIONS permission
        }
    }
    
    private fun cancelNotification() {
         if (activity != null) {
             androidx.core.app.NotificationManagerCompat.from(activity!!).cancel(1)
         }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        mediaSession?.release()
        mediaSession = null
    }

    // --- MethodCallHandler Interface ---

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "enableAutoPip" -> {
                activePlayerId = call.argument<Int>("playerId")
                val width = call.argument<Int>("width")
                val height = call.argument<Int>("height")
                updatePipParams(width, height) // Sets the "Auto-Enter" flag for Android 12+
                result.success(true)
            }
            "disableAutoPip" -> {
                activePlayerId = null
                disableAutoPip()
                result.success(true)
            }
            "enterPipMode" -> {
                val playerId = call.argument<Int>("playerId") ?: -1
                val width = call.argument<Int>("width")
                val height = call.argument<Int>("height")
                result.success(enterPipMode(playerId, width, height))
            }
            "isInPipMode" -> result.success(isInPipMode)
            "updateMediaState" -> {
                val state = call.argument<Int>("state") ?: android.support.v4.media.session.PlaybackStateCompat.STATE_NONE
                updatePlaybackState(state)
                result.success(true)
            }
            "updateMediaMetadata" -> {
                val title = call.argument<String>("title")
                val artist = call.argument<String>("artist")
                updateMediaMetadata(title, artist)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // --- PiP Logic ---

    private fun enterPipMode(playerId: Int, customWidth: Int?, customHeight: Int?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity == null) return false
        
        val params = buildPipParams(playerId, customWidth, customHeight)
        return activity?.enterPictureInPictureMode(params) ?: false
    }

    private fun updatePipParams(width: Int? = null, height: Int? = null) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activePlayerId != null) {
            val params = buildPipParams(activePlayerId!!, width, height)
            activity?.setPictureInPictureParams(params)
        }
    }

    private fun disableAutoPip() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val builder = PictureInPictureParams.Builder()
            builder.setAutoEnterEnabled(false)
            activity?.setPictureInPictureParams(builder.build())
        }
    }

    private fun buildPipParams(playerId: Int, width: Int?, height: Int?): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        
        // Use custom dimensions if provided, otherwise check view
        if (width != null && height != null) {
             builder.setAspectRatio(Rational(width, height))
        } else {
             val videoView = findVideoPlayerView(playerId)
             if (videoView != null) {
                 val vWidth = videoView.width.coerceAtLeast(1)
                 val vHeight = videoView.height.coerceAtLeast(1)
                 builder.setAspectRatio(Rational(vWidth, vHeight))

                 val rect = Rect()
                 videoView.getGlobalVisibleRect(rect)
                 builder.setSourceRectHint(rect)
             }
        }
        
        // NOTE: RemoteActions removed. MediaSession automatically handles PiP actions.

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(true)
            builder.setSeamlessResizeEnabled(true)
        }
        
        return builder.build()
    }
    
    private fun findVideoPlayerView(playerId: Int): View? {
        val rootView = activity?.findViewById<ViewGroup>(android.R.id.content)
        return findVideoPlayerViewRecursively(rootView)
    }

    private fun findVideoPlayerViewRecursively(view: View?): View? {
        if (view == null) return null
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findVideoPlayerViewRecursively(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }

    // --- ActivityAware Interface ---

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnUserLeaveHintListener(userLeaveHintListener)
        setupPipModeChangeListener()
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnUserLeaveHintListener(userLeaveHintListener)
        cleanupPipModeChangeListener()
        activity = null
        activityBinding = null
    }

    // ... (rest of lifecycle methods)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    private fun setupPipModeChangeListener() {
        componentCallback = object : android.content.ComponentCallbacks {
            override fun onConfigurationChanged(newConfig: Configuration) {
                val currentMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    activity?.isInPictureInPictureMode ?: false
                } else false

                if (isInPipMode != currentMode) {
                    isInPipMode = currentMode
                    channel.invokeMethod("pipModeChanged", mapOf("isInPipMode" to isInPipMode))

                    if (!isInPipMode) {
                        // PiP mode exited. Check if it's a restore or a dismiss.
                        // If the activity is not RESUMED or STARTED, it's likely a dismiss (closed via X).
                         val state = (activity as? androidx.lifecycle.LifecycleOwner)?.lifecycle?.currentState
                         if (state == androidx.lifecycle.Lifecycle.State.CREATED || state == androidx.lifecycle.Lifecycle.State.DESTROYED) {
                             channel.invokeMethod("pipDismissed", null)
                         }
                         // Note: If state is STARTED/RESUMED, it's a restore.
                         // Fallback: Sometimes state update lags. If we are just PAUSED/STOPPED, assume dismiss.
                    }
                }
            }
            override fun onLowMemory() {}
        }
        activity?.registerComponentCallbacks(componentCallback)
    }

    private fun cleanupPipModeChangeListener() {
        activity?.unregisterComponentCallbacks(componentCallback)
    }
}