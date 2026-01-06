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

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "video_player_pip")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
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