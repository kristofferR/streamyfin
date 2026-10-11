import AVFAudio
import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import UIKit

/// Delegate mirroring `MPVLayerRendererDelegate` granularity so the two hosts
/// (`MpvPlayerView` for the RN-embedded player, `NativePlayerViewController`
/// for the presented native player) can map callbacks 1:1 onto their own
/// event surfaces without any payload translation. All callbacks arrive on
/// the main thread.
protocol MPVPlayerEngineDelegate: AnyObject {
	func engine(_ engine: MPVPlayerEngine, didLoad url: URL)
	func engine(_ engine: MPVPlayerEngine, didUpdateProgress position: Double, duration: Double, cacheSeconds: Double)
	func engine(_ engine: MPVPlayerEngine, didChangePause isPaused: Bool)
	func engine(_ engine: MPVPlayerEngine, didChangeLoading isLoading: Bool)
	func engine(_ engine: MPVPlayerEngine, didBecomeReadyToSeek ready: Bool)
	func engine(_ engine: MPVPlayerEngine, didBecomeTracksReady ready: Bool)
	func engine(_ engine: MPVPlayerEngine, didChangePictureInPicture isActive: Bool)
	func engine(_ engine: MPVPlayerEngine, didFailWithError message: String)
	func engine(_ engine: MPVPlayerEngine, didDetectHDRMode mode: HDRMode, fps: Double)
	func engineDidReachEnd(_ engine: MPVPlayerEngine)
	/// Seeks the engine receives from the system — lock screen, Control
	/// Center, PiP. A host that keeps its own position bookkeeping performs
	/// the seek itself so it is treated like every other seek; the engine only
	/// forwards the request.
	func engine(_ engine: MPVPlayerEngine, requestsSeekTo position: Double)
	func engine(_ engine: MPVPlayerEngine, requestsSeekBy offset: Double)
	func engine(_ engine: MPVPlayerEngine, requestsPlaying playing: Bool)
}

/// Hosts without position bookkeeping of their own let the engine seek.
extension MPVPlayerEngineDelegate {
	func engine(_ engine: MPVPlayerEngine, requestsPlaying playing: Bool) {
		if playing { engine.play() } else { engine.pause() }
	}
	func engine(_ engine: MPVPlayerEngine, requestsSeekTo position: Double) {
		engine.seekTo(position: position)
	}

	func engine(_ engine: MPVPlayerEngine, requestsSeekBy offset: Double) {
		engine.seekBy(offset: offset)
	}
}

/// Non-UI playback engine: owns the display layer, the libmpv renderer, PiP,
/// Now Playing and the audio session. Hosts are responsible only for putting
/// `displayLayer` into a layer tree and keeping its frame updated.
final class MPVPlayerEngine: NSObject {
	weak var delegate: MPVPlayerEngineDelegate?

	/// Hosts add this to their layer tree and update its frame on layout.
	let displayLayer = AVSampleBufferDisplayLayer()

	private var renderer: MPVLayerRenderer?
	/// Plays TrueHD Atmos and DTS:X as spatial audio in mpv's place, once
	/// started; see SpatialAudioPlayer.
	private var spatialAudio: SpatialAudioPlayer?
	/// What mpv plays if spatial audio fails. Set from the moment it starts
	/// until it stops, so mpv events and transport stay out of the way.
	private var spatialAudioFallback: VideoLoadConfig?
	private var pipController: PiPController?
	private let nowPlayingManager = MPVNowPlayingManager.shared
	private let audioSession = PlayerAudioSession.shared

	private var currentURL: URL?
	private var currentLoop = false
	private var cachedPosition: Double = 0
	private var cachedDuration: Double = 0
	private var loadGeneration: UInt = 0
	private(set) var intendedPlayState: Bool = false
	private var _isZoomedToFill: Bool = false
	private var isShutDown = false
	// Outside the iOS block below: the PiP delegate that sets these compiles
	// on tvOS too, where it is never called.
	/// True while the delegate hears that PiP stopped, when the user asked to
	/// return to the app. False when the PiP window was simply closed.
	private(set) var pictureInPictureStopIsRestore = false
	/// True from AVKit announcing that PiP will stop until it has stopped.
	private(set) var isPictureInPictureStopping = false
	/// True from AVKit announcing that PiP will start until it has started or
	/// failed to. Automatic PiP begins as the app leaves the foreground, and
	/// the app can be in the background before the window is up.
	private(set) var isPictureInPictureStarting = false
	#if os(iOS)
	private var isPictureInPictureHostVisible = false
	private var hasRenderedFirstFrame = false
	private var pictureInPictureAutoStartEnabled = false
	#endif

	override init() {
		super.init()

		displayLayer.videoGravity = .resizeAspect
		#if !os(tvOS)
		if #available(iOS 17.0, *) {
			displayLayer.wantsExtendedDynamicRangeContent = true
		}
		#endif
		displayLayer.backgroundColor = UIColor.black.cgColor

		renderer = MPVLayerRenderer(displayLayer: displayLayer)
		renderer?.delegate = self

		NotificationCenter.default.addObserver(
			self, selector: #selector(handleAudioSessionInterruption),
			name: AVAudioSession.interruptionNotification, object: nil)

		#if os(iOS)
		NotificationCenter.default.addObserver(
			self, selector: #selector(handleDidBecomeActive),
			name: UIApplication.didBecomeActiveNotification, object: nil)
		#endif

		// tvOS has no windowed/minimized state: leaving the app backgrounds it
		// outright. The `audio` background mode keeps our `.playback` session
		// alive across that, so mpv would go on decoding audio behind the Home
		// screen with nothing on screen to stop it. Pause instead. Owned here
		// rather than by the host so BOTH hosts (RN-embedded view and presented
		// native player) inherit it.
		#if os(tvOS)
		NotificationCenter.default.addObserver(
			self, selector: #selector(handleDidEnterBackground),
			name: UIApplication.didEnterBackgroundNotification, object: nil)
		#endif
	}

	#if os(iOS)
	@objc private func handleDidBecomeActive() {
		guard !isShutDown, !isPictureInPictureActive() else { return }
		renderer?.restoreSubtitlesAfterForeground()
	}
	#endif

	#if os(tvOS)
	/// PiP would be the one way playback is *meant* to outlive the foreground
	/// app, so it opts out. Today that guard never fires on tvOS: AVKit never
	/// engages PiP for an AVSampleBufferDisplayLayer content source there (it
	/// reports isPictureInPictureSupported() == true but leaves
	/// isPictureInPicturePossible false forever and never calls the sample
	/// buffer playback delegate), and mpv has no AVPlayerLayer to offer
	/// instead. Kept so this stays correct if Apple ever ships the fix.
	@objc private func handleDidEnterBackground() {
		guard !isPictureInPictureActive() else { return }
		pause()
	}
	#endif

	func start() throws {
		try renderer?.start()
	}

	// MARK: - Audio Session

	// Every change to the session goes through `PlayerAudioSession`, off the
	// main thread. Nothing re-activates it after the interruption handled
	// below except the play() that resumes, which is why play() still applies
	// it every time.

	/// Not after a shutdown: a play() or an mpv callback can still arrive once
	/// the player has closed, and an activation queued behind the teardown
	/// would take the session back with no player left to give it up.
	private func activateAudioSession(completion: (() -> Void)? = nil) {
		guard !isShutDown else { return }
		audioSession.activate(spatialAudio: spatialAudioFallback != nil, completion: completion)
	}

	@objc private func handleAudioSessionInterruption(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
			  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
			  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
			return
		}

		switch type {
		case .began:
			// Interruption began - pause the video
			print("[MPV] Audio session interrupted - pausing video")
			self.pause()

		case .ended:
			// Interruption ended - check if we should resume
			if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
				let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
				if options.contains(.shouldResume) {
					print("[MPV] Audio session interruption ended - can resume")
					// Don't auto-resume - let user manually resume playback
				} else {
					print("[MPV] Audio session interruption ended - should not resume")
				}
			}

		@unknown default:
			break
		}
	}

	private func setupRemoteCommands() {
		nowPlayingManager.setupRemoteCommands(
			playHandler: { [weak self] in self?.requestPlaying(true) },
			pauseHandler: { [weak self] in self?.requestPlaying(false) },
			toggleHandler: { [weak self] in
				guard let self else { return }
				self.requestPlaying(!self.intendedPlayState)
			},
			seekHandler: { [weak self] time in self?.requestSeek(to: time) },
			skipForward: { [weak self] interval in self?.requestSeek(by: interval) },
			skipBackward: { [weak self] interval in self?.requestSeek(by: -interval) }
		)
	}

	// MARK: - Now Playing Info

	func setNowPlayingMetadata(_ metadata: [String: String], artworkHeaders: [String: String]? = nil) {
		print("[MPV] setNowPlayingMetadata: \(metadata["title"] ?? "nil")")
		nowPlayingManager.setMetadata(
			title: metadata["title"],
			artist: metadata["artist"],
			albumTitle: metadata["albumTitle"],
			artworkUrl: metadata["artworkUri"],
			artworkHeaders: artworkHeaders
		)
	}

	private func clearNowPlayingInfo() {
		nowPlayingManager.cleanupRemoteCommands()
		nowPlayingManager.clear()
	}

	/// Single location for Now Playing updates
	private func syncNowPlaying(isPlaying: Bool) {
		print("[MPV] syncNowPlaying: pos=\(Int(cachedPosition))s, dur=\(Int(cachedDuration))s, playing=\(isPlaying)")
		nowPlayingManager.updatePlayback(position: cachedPosition, duration: cachedDuration, isPlaying: isPlaying)
	}

	// MARK: - Loading

	/// - Parameter force: reload even when the URL matches the current one.
	///   The presented native player re-negotiates streams in place (burned-in
	///   subtitles, bitrate changes) where the URL can legitimately repeat.
	func loadVideo(config: VideoLoadConfig, force: Bool = false) {
		// Skip reload if the same URL and loop mode are already playing.
		if !force && currentURL == config.url && currentLoop == config.loop {
			return
		}
		currentURL = config.url
		currentLoop = config.loop
		loadGeneration &+= 1
		let currentLoadGeneration = loadGeneration
		#if os(iOS)
		hasRenderedFirstFrame = false
		#endif
		setPictureInPictureAutoStartEnabled(true)
		stopSpatialAudio()

		#if os(tvOS)
		if #available(tvOS 26, *), let source = config.spatialAudio {
			startSpatialAudio(source, config: config, loadGeneration: currentLoadGeneration)
		} else {
			loadInMPV(config, loadGeneration: currentLoadGeneration)
		}
		#else
		loadInMPV(config, loadGeneration: currentLoadGeneration)
		#endif

		delegate?.engine(self, didLoad: config.url)
	}

	private func loadInMPV(_ config: VideoLoadConfig, loadGeneration: UInt) {
		let preset = PlayerPreset(
			id: .sdrRec709,
			title: "Default",
			summary: "Default playback preset",
			stream: nil,
			commands: []
		)

		// Queued ahead of the load on purpose. The renderer's load block waits
		// for pending session changes, so the playback category is in place
		// before mpv opens its audio output, which sizes itself from the route
		// the session reports at that moment.
		if config.autoplay {
			activateAudioSession()
		}

		// Pass everything to the renderer - it handles start position and external subs
		renderer?.load(
			url: config.url,
			with: preset,
			headers: config.headers,
			startPosition: config.startPosition,
			externalSubtitles: config.externalSubtitles,
			initialSubtitleId: config.initialSubtitleId,
			initialAudioId: config.initialAudioId,
			loop: config.loop,
			cacheEnabled: config.cacheEnabled,
			cacheSeconds: config.cacheSeconds,
			demuxerMaxBytes: config.demuxerMaxBytes,
			demuxerMaxBackBytes: config.demuxerMaxBackBytes,
			loadGeneration: loadGeneration
		)

		// A SyncPlay late join loads paused. Remote Play and Seek must already
		// have intent handlers before the first group Unpause ever arrives.
		setupRemoteCommands()
		if config.autoplay {
			resumePlayback()
		} else {
			// mpv's pause property survives loadfile. A shared queue restart
			// must stay paused until Jellyfin's scheduled Unpause, even when
			// the previous source was playing or reached EOF while unpaused.
			pause()
		}
	}

	#if os(tvOS)
	/// Converting the first segment takes about two seconds, so the chrome
	/// shows loading meanwhile. Any error leaves the stream to mpv.
	@available(tvOS 26, *)
	private func startSpatialAudio(_ source: SpatialAudioSource, config: VideoLoadConfig, loadGeneration: UInt) {
		spatialAudioFallback = config
		// An in-place swap leaves the previous file playing in mpv.
		renderer?.unload()
		intendedPlayState = config.autoplay
		setupRemoteCommands()
		delegate?.engine(self, didChangeLoading: true)
		Task { @MainActor [weak self] in
			do {
				let player = try await SpatialAudioPlayer.start(
					source: source, file: config.url, headers: config.headers ?? [:],
					at: config.startPosition ?? 0)
				guard let self, loadGeneration == self.loadGeneration, !self.isShutDown else {
					player.stop()
					return
				}
				self.spatialAudio = player
				player.layer.frame = self.displayLayer.bounds
				player.layer.videoGravity = self.displayLayer.videoGravity
				self.displayLayer.addSublayer(player.layer)
				// Set on the renderer while the stream was starting.
				player.setSpeed(self.getSpeed())
				player.setMuted(self.renderer?.isMuted ?? false)
				player.report(to: self)
				guard self.intendedPlayState else { return }
				// AVPlayer does not wait for the session change the way mpv's
				// unpause does, and the first play has to find it in place.
				self.activateAudioSession { [weak self, weak player] in
					guard let self, let player, player === self.spatialAudio, self.intendedPlayState else { return }
					self.resumePlayback()
				}
			} catch {
				Logger.shared.log("Spatial audio unavailable, playing through mpv: \(error)", type: "Warn")
				guard let self, loadGeneration == self.loadGeneration, !self.isShutDown else { return }
				self.fallBackToMPV(at: config.startPosition)
			}
		}
	}
	#endif

	private func fallBackToMPV(at position: Double?) {
		guard var config = spatialAudioFallback else { return }
		stopSpatialAudio()
		config.startPosition = position
		config.autoplay = intendedPlayState
		loadInMPV(config, loadGeneration: loadGeneration)
	}

	private func stopSpatialAudio() {
		spatialAudio?.stop()
		spatialAudio = nil
		spatialAudioFallback = nil
	}

	// MARK: - Transport

	func play() {
		// Queued before the unpause, which renderer.play() holds until the
		// session is active.
		activateAudioSession()
		resumePlayback()
	}

	/// play() without the session request: loadVideo() has to make that one
	/// before the load is queued, and once is enough.
	private func resumePlayback() {
		intendedPlayState = true
		setupRemoteCommands()
		if spatialAudioFallback != nil {
			spatialAudio?.play()
			return
		}
		renderer?.play()
		pipController?.setPlaybackRate(1.0)
		pipController?.updatePlaybackState()
	}

	func pause() {
		intendedPlayState = false
		if spatialAudioFallback != nil {
			spatialAudio?.pause()
			return
		}
		renderer?.pausePlayback()
		pipController?.setPlaybackRate(0.0)
		pipController?.updatePlaybackState()
	}

	/**
	 * Synchronously stop and destroy the mpv instance + decoder so memory is
	 * freed before the next screen mounts. Safe to call multiple times — the
	 * underlying renderer.stop() guards against re-entry.
	 *
	 * Cross-platform counterpart of MpvPlayerView.destroy() on Android.
	 */
	func destroy() {
		loadGeneration &+= 1
		// Release the system's single inline auto-PiP slot now; deinit is deferred
		// and would otherwise keep it claimed, blocking PiP for the next video.
		setPictureInPictureAutoStartEnabled(false)
		pipController?.stopPictureInPicture()
		pipController = nil
		stopSpatialAudio()
		renderer?.stop()

		// Reset state and re-create the mpv handle so a subsequent
		// loadVideo() on the SAME engine instance can actually load.
		// Without this, stop() leaves renderer.mpv == nil, and the next
		// loadVideo(config:) calls renderer.load() which early-returns
		// at `guard let handle = self.mpv else { return }` — but only
		// after flipping isLoading = true and dispatching the loading
		// delegate callback, so the JS layer is stuck in a perpetual
		// "loading" state with no actual playback.
		//
		// This path is hit by direct-player.tsx's goToNextItem()/stop(),
		// which call destroy() immediately before router.replace() to
		// the same route — Expo Router reuses the same MpvPlayerView
		// instance, so the next `source` prop update arrives on this
		// view without a remount. Engine init is otherwise the only
		// place start() is called, so without re-starting here the
		// renderer stays dead until the whole host is deallocated and
		// recreated.
		//
		// start() is idempotent (`guard !isRunning else { return }`)
		// and stop() has already nulled mpv synchronously before
		// dispatching the async mpv_terminate_destroy, so creating a
		// fresh handle here is safe even while the old handle's
		// teardown is still in flight on a background queue (libmpv
		// handles are independent).
		currentURL = nil
		currentLoop = false
		intendedPlayState = false
		do {
			try renderer?.start()
		} catch {
			delegate?.engine(self, didFailWithError: "Failed to restart renderer after destroy: \(error.localizedDescription)")
		}
	}

	/// Full teardown for hosts that are going away. Idempotent; mirrors the
	/// old MpvPlayerView.deinit ordering (PiP → renderer → layer → Now
	/// Playing → audio session). The renderer's stop() already performs
	/// mpv_terminate_destroy on a background queue — never reorder that.
	func shutdown() {
		guard !isShutDown else { return }
		isShutDown = true
		setPictureInPictureAutoStartEnabled(false)
		pipController?.stopPictureInPicture()
		pipController = nil
		stopSpatialAudio()
		renderer?.stop()
		displayLayer.removeFromSuperlayer()
		clearNowPlayingInfo()
		audioSession.tearDown()
		NotificationCenter.default.removeObserver(self)
	}

	deinit {
		shutdown()
	}

	func seekTo(position: Double, exact: Bool = false) {
		// Update cached position and Now Playing immediately for smooth Control Center feedback
		cachedPosition = position
		syncNowPlaying(isPlaying: !isPaused())
		if spatialAudioFallback != nil {
			spatialAudio?.seek(to: position)
			return
		}
		renderer?.seek(to: position, exact: exact)
	}

	func seekBy(offset: Double) {
		// Update cached position and Now Playing immediately for smooth Control Center feedback
		let newPosition = max(0, min(cachedPosition + offset, cachedDuration))
		cachedPosition = newPosition
		syncNowPlaying(isPlaying: !isPaused())
		if spatialAudioFallback != nil {
			spatialAudio?.seek(to: newPosition)
			return
		}
		renderer?.seek(by: offset)
	}

	/// Seeks from the lock screen, Control Center and PiP go through the
	/// delegate: the native player's view model owns the tracked position, the
	/// seek report and the synthetic tick, and a seek that bypasses it leaves
	/// onDismiss on the pre-seek position until the next time-pos tick and the
	/// server until the next heartbeat.
	func requestSeek(to position: Double) {
		if let delegate {
			delegate.engine(self, requestsSeekTo: position)
		} else {
			seekTo(position: position)
		}
	}

	func requestPlaying(_ playing: Bool) {
		if let delegate { delegate.engine(self, requestsPlaying: playing) }
		else if playing { play() } else { pause() }
	}

	func requestSeek(by offset: Double) {
		if let delegate {
			delegate.engine(self, requestsSeekBy: offset)
		} else {
			seekBy(offset: offset)
		}
	}

	func syncSubtitleLayerFrame() {
		spatialAudio?.layer.frame = displayLayer.bounds
		renderer?.syncSubtitleLayerFrame()
	}

	func setSpeed(speed: Double) {
		spatialAudio?.setSpeed(speed)
		renderer?.setSpeed(speed)
	}

	/// Mute playback itself, leaving the device output volume alone. The
	/// renderer retains the flag so it survives an mpv re-creation.
	func setMute(_ muted: Bool) {
		spatialAudio?.setMuted(muted)
		renderer?.setMute(muted)
	}

	func getSpeed() -> Double {
		return renderer?.getSpeed() ?? 1.0
	}

	func isPaused() -> Bool {
		if spatialAudioFallback != nil {
			return spatialAudio?.isPaused ?? !intendedPlayState
		}
		return renderer?.isPausedState ?? true
	}

	func getCurrentPosition() -> Double {
		return cachedPosition
	}

	func getDuration() -> Double {
		return cachedDuration
	}

	// MARK: - Picture in Picture

	func setPictureInPictureAutoStartEnabled(_ enabled: Bool) {
		#if os(iOS)
		pictureInPictureAutoStartEnabled = enabled
		reconcilePictureInPictureState()
		#endif
	}

	func setPictureInPictureHostVisible(_ visible: Bool) {
		#if os(iOS)
		isPictureInPictureHostVisible = visible
		reconcilePictureInPictureState()
		#endif
	}

	func startPictureInPicture() {
		#if os(iOS)
		guard isPictureInPictureHostVisible, hasRenderedFirstFrame else {
			Logger.shared.log(
				"PiP: start refused — hosted playback is not eligible",
				type: "Warn")
			return
		}
		reconcilePictureInPictureState(allowManualStart: true)
		#endif
		Logger.shared.log(
			"PiP: engine asked to start (duration=\(getDuration()) playing=\(!isPaused()))",
			type: "Info")
		guard let pipController else {
			Logger.shared.log(
				"PiP: start refused — hosted playback has not rendered its first frame",
				type: "Warn")
			return
		}
		pipController.startPictureInPicture()
	}

	func stopPictureInPicture() {
		pipController?.stopPictureInPicture()
	}

	/// A device capability, so one answer serves the whole process. AVKit's
	/// own answer is not free: PlayerTopBar asks from its SwiftUI body, on
	/// every evaluation, and one such call held the main thread for 4 seconds
	/// (Sentry REACT-NATIVE-FC). Resolved once, on first use, by whoever asks.
	/// Deliberately not warmed from a background queue: main would then wait
	/// on this initializer, and if AVKit needs the main thread to answer, the
	/// two wait on each other for good.
	private static let pictureInPictureSupported =
		AVPictureInPictureController.isPictureInPictureSupported()

	func isPictureInPictureSupported() -> Bool {
		return MPVPlayerEngine.pictureInPictureSupported
	}

	func isPictureInPictureActive() -> Bool {
		return pipController?.isPictureInPictureActive ?? false
	}

	#if os(iOS)
	private func reconcilePictureInPictureState(
		allowManualStart: Bool = false
	) {
		guard !isShutDown,
			  isPictureInPictureHostVisible,
			  pictureInPictureAutoStartEnabled || allowManualStart,
			  hasRenderedFirstFrame else {
			pipController?.setAutoStartEnabled(false)
			return
		}

		if pipController == nil {
			let controller = PiPController(
				sampleBufferDisplayLayer: displayLayer,
				delegate: self
			)
			pipController = controller
			controller.setPlaybackRate(intendedPlayState ? 1.0 : 0.0)
			controller.setCurrentTimeFromSeconds(cachedPosition)
			Logger.shared.log(
				"PiP: controller prepared after hosted playback became ready "
					+ "(position=\(cachedPosition) duration=\(cachedDuration))",
				type: "Info")
		}
		pipController?.setAutoStartEnabled(pictureInPictureAutoStartEnabled)
	}
	#endif

	// MARK: - Subtitle Controls

	/// Completion fires on the renderer's mpv work queue; hop to main before
	/// touching UI state.
	func getSubtitleTracks(completion: @escaping ([[String: Any]]) -> Void) {
		guard let renderer else { return completion([]) }
		renderer.getSubtitleTracks(completion: completion)
	}

	/// While spatial audio plays, `trackId` is the 1-based subtitle rendition
	/// of the HLS master instead of an mpv track id.
	func setSubtitleTrack(_ trackId: Int) {
		if let spatialAudio {
			spatialAudio.selectSubtitle(trackId)
			return
		}
		renderer?.setSubtitleTrack(trackId)
	}

	func disableSubtitles() {
		if let spatialAudio {
			spatialAudio.selectSubtitle(nil)
			return
		}
		renderer?.disableSubtitles()
	}

	/// Whether the stream plays as spatial audio rather than through mpv.
	var isPlayingSpatialAudio: Bool {
		spatialAudio != nil
	}

	func getCurrentSubtitleTrack(completion: @escaping (Int) -> Void) {
		guard let renderer else { return completion(0) }
		renderer.getCurrentSubtitleTrack(completion: completion)
	}

	func addSubtitleFile(url: String, select: Bool = true) {
		renderer?.addSubtitleFile(url: url, select: select)
	}

	// MARK: - Audio Track Controls

	/// Completion fires on the renderer's mpv work queue (see getSubtitleTracks).
	func getAudioTracks(completion: @escaping ([[String: Any]]) -> Void) {
		guard let renderer else { return completion([]) }
		renderer.getAudioTracks(completion: completion)
	}

	func setAudioTrack(_ trackId: Int) {
		renderer?.setAudioTrack(trackId)
	}

	func getCurrentAudioTrack(completion: @escaping (Int) -> Void) {
		guard let renderer else { return completion(0) }
		renderer.getCurrentAudioTrack(completion: completion)
	}

	// MARK: - Subtitle Positioning

	func setSubtitlePosition(_ position: Int) {
		renderer?.setSubtitlePosition(position)
	}

	func setSubtitleScale(_ scale: Double) {
		renderer?.setSubtitleScale(scale)
	}

	func setSubtitleDelay(_ seconds: Double) {
		renderer?.setSubtitleDelay(seconds)
	}

	func setAudioDelay(_ seconds: Double) {
		renderer?.setAudioDelay(seconds)
	}

	/// Software gain in percent: 100 = neutral, above amplifies (mpv softvol).
	func setVolumeBoost(_ percent: Int) {
		renderer?.setVolumeBoost(percent)
	}

	/// Speech-clarity EQ toggle (bass cut + presence boost via mpv af/lavfi).
	func setDialogueBoost(_ enabled: Bool) {
		renderer?.setDialogueBoost(enabled)
	}

	/// Accessibility mono downmix (mpv audio-channels).
	func setMonoDownmix(_ enabled: Bool) {
		renderer?.setMonoDownmix(enabled)
	}

	func setSubtitleMarginY(_ margin: Int) {
		renderer?.setSubtitleMarginY(margin)
	}

	func setSubtitleAlignX(_ alignment: String) {
		renderer?.setSubtitleAlignX(alignment)
	}

	func setSubtitleAlignY(_ alignment: String) {
		renderer?.setSubtitleAlignY(alignment)
	}

	func setSubtitleFontSize(_ size: Int) {
		renderer?.setSubtitleFontSize(size)
	}

	func setSubtitleStyle(config: [String: Any]) {
		renderer?.setSubtitleStyle(config: config)
	}

	func setSubtitleBackgroundColor(_ color: String) {
		renderer?.setSubtitleBackgroundColor(color)
	}

	func setSubtitleBorderStyle(_ style: String) {
		renderer?.setSubtitleBorderStyle(style)
	}

	func setSubtitleAssOverride(_ mode: String) {
		renderer?.setSubtitleAssOverride(mode)
	}

	// MARK: - Video Scaling

	func setZoomedToFill(_ zoomed: Bool) {
		_isZoomedToFill = zoomed
		displayLayer.videoGravity = zoomed ? .resizeAspectFill : .resizeAspect
		spatialAudio?.layer.videoGravity = displayLayer.videoGravity
		renderer?.syncSubtitleLayerFrame()
	}

	func isZoomedToFill() -> Bool {
		return _isZoomedToFill
	}

	// MARK: - Technical Info

	/// Completion fires on the renderer's mpv work queue (see getSubtitleTracks).
	func getTechnicalInfo(completion: @escaping ([String: Any]) -> Void) {
		if let spatialAudio { return completion(spatialAudio.technicalInfo()) }
		guard let renderer else { return completion([:]) }
		renderer.getTechnicalInfo(completion: completion)
	}
}

// MARK: - MPVLayerRendererDelegate

extension MPVPlayerEngine: MPVLayerRendererDelegate {
	func renderer(_: MPVLayerRenderer, didUpdatePosition position: Double, duration: Double, cacheSeconds: Double) {
		cachedPosition = position
		cachedDuration = duration

		DispatchQueue.main.async { [weak self] in
			guard let self, self.spatialAudioFallback == nil else { return }

			if self.pipController?.isPictureInPictureActive == true {
				self.pipController?.setCurrentTimeFromSeconds(position)
			}

			self.delegate?.engine(self, didUpdateProgress: position, duration: duration, cacheSeconds: cacheSeconds)
		}
	}

	func renderer(_: MPVLayerRenderer, didChangePause isPaused: Bool) {
		DispatchQueue.main.async { [weak self] in
			guard let self, self.spatialAudioFallback == nil else { return }

			print("[MPV] didChangePause: isPaused=\(isPaused), cachedDuration=\(self.cachedDuration)")
			self.pipController?.setPlaybackRate(isPaused ? 0.0 : 1.0)
			self.syncNowPlaying(isPlaying: !isPaused)
			self.delegate?.engine(self, didChangePause: isPaused)
		}
	}

	func renderer(_: MPVLayerRenderer, didChangeLoading isLoading: Bool) {
		DispatchQueue.main.async { [weak self] in
			guard let self, self.spatialAudioFallback == nil else { return }
			self.delegate?.engine(self, didChangeLoading: isLoading)
		}
	}

	func renderer(_: MPVLayerRenderer, didBecomeReadyToSeek ready: Bool) {
		DispatchQueue.main.async { [weak self] in
			guard let self, self.spatialAudioFallback == nil else { return }
			self.delegate?.engine(self, didBecomeReadyToSeek: ready)
		}
	}

	func renderer(_: MPVLayerRenderer, didBecomeTracksReady ready: Bool) {
		DispatchQueue.main.async { [weak self] in
			guard let self, self.spatialAudioFallback == nil else { return }
			self.delegate?.engine(self, didBecomeTracksReady: ready)
		}
	}

	func renderer(_: MPVLayerRenderer, didDetectHDRMode mode: HDRMode, fps: Double) {
		DispatchQueue.main.async { [weak self] in
			guard let self, self.spatialAudioFallback == nil else { return }
			self.delegate?.engine(self, didDetectHDRMode: mode, fps: fps)
		}
	}

	func renderer(_: MPVLayerRenderer, didSelectAudioOutput audioOutput: String) {
		print("[MPV] Audio output ready (\(audioOutput)), syncing Now Playing")
		// mpv reconfigures the shared AVAudioSession when its audio unit spins up,
		// overriding what play() set. Until ours is re-applied the system doesn't
		// treat us as the Now Playing app and drops every info update.
		activateAudioSession { [weak self] in
			// A shutdown in between has cleared Now Playing; leave it cleared.
			guard let self, !self.isShutDown else { return }
			self.syncNowPlaying(isPlaying: self.intendedPlayState)
		}
	}

	func rendererPlaybackDidRestart(
		_: MPVLayerRenderer,
		loadGeneration: UInt
	) {
		guard loadGeneration == self.loadGeneration else { return }
		#if os(iOS)
		hasRenderedFirstFrame = true
		reconcilePictureInPictureState()
		#endif
	}

	func rendererDidReachEnd(_: MPVLayerRenderer) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.delegate?.engineDidReachEnd(self)
		}
	}
}

// MARK: - SpatialAudioPlayerDelegate

extension MPVPlayerEngine: SpatialAudioPlayerDelegate {
	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didUpdatePosition position: Double, duration: Double) {
		guard player === spatialAudio else { return }
		cachedPosition = position
		cachedDuration = duration
		delegate?.engine(self, didUpdateProgress: position, duration: duration, cacheSeconds: 0)
	}

	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didChangePause isPaused: Bool) {
		guard player === spatialAudio else { return }
		syncNowPlaying(isPlaying: !isPaused)
		delegate?.engine(self, didChangePause: isPaused)
	}

	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didChangeLoading isLoading: Bool) {
		guard player === spatialAudio else { return }
		delegate?.engine(self, didChangeLoading: isLoading)
	}

	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didBecomeReadyWith hdrMode: HDRMode, fps: Double) {
		guard player === spatialAudio else { return }
		delegate?.engine(self, didBecomeReadyToSeek: true)
		delegate?.engine(self, didBecomeTracksReady: true)
		delegate?.engine(self, didDetectHDRMode: hdrMode, fps: fps)
	}

	func spatialAudioPlayerDidReachEnd(_ player: SpatialAudioPlayer) {
		guard player === spatialAudio else { return }
		delegate?.engineDidReachEnd(self)
	}

	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didFailAt position: Double) {
		guard player === spatialAudio else { return }
		fallBackToMPV(at: position)
	}
}

// MARK: - PiPControllerDelegate

extension MPVPlayerEngine: PiPControllerDelegate {
	func pipController(_ controller: PiPController, willStartPictureInPicture: Bool) {
		Logger.shared.log("PiP: will start", type: "Info")
		pictureInPictureStopIsRestore = false
		isPictureInPictureStopping = false
		isPictureInPictureStarting = true
		// Sync timebase before PiP starts for smooth transition
		renderer?.syncTimebase()
		// Set current time for PiP progress bar
		pipController?.setCurrentTimeFromSeconds(cachedPosition)

		// Reset to fit for PiP (zoomed video doesn't display correctly in PiP)
		if _isZoomedToFill {
			displayLayer.videoGravity = .resizeAspect
			renderer?.syncSubtitleLayerFrame()
		}
	}

	func pipController(_ controller: PiPController, didStartPictureInPicture: Bool) {
		Logger.shared.log("PiP: did start = \(didStartPictureInPicture)", type: "Info")
		isPictureInPictureStarting = false
		// Ensure current time is synced when PiP starts
		pipController?.setCurrentTimeFromSeconds(cachedPosition)
		// Notify the host of the actual PiP active state. `didStartPictureInPicture`
		// is `false` when AVKit reports a failure to start, so reflect that.
		delegate?.engine(self, didChangePictureInPicture: didStartPictureInPicture)
	}

	func pipController(_ controller: PiPController, willStopPictureInPicture: Bool) {
		Logger.shared.log("PiP: will stop", type: "Info")
		isPictureInPictureStopping = true
		// Sync timebase before returning from PiP
		renderer?.syncTimebase()
	}

	func pipController(_ controller: PiPController, didStopPictureInPicture: Bool) {
		Logger.shared.log("PiP: did stop", type: "Info")
		isPictureInPictureStarting = false
		// Ensure timebase is synced after PiP ends
		renderer?.syncTimebase()
		pipController?.updatePlaybackState()

		// Restore the user's zoom preference
		if _isZoomedToFill {
			displayLayer.videoGravity = .resizeAspectFill
			renderer?.syncSubtitleLayerFrame()
		}
		// Notify the host that PiP has fully stopped so the controls overlay
		// can be re-mounted when the user returns to full screen.
		delegate?.engine(self, didChangePictureInPicture: false)
		pictureInPictureStopIsRestore = false
		isPictureInPictureStopping = false
	}

	func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void) {
		Logger.shared.log("PiP: restore user interface requested", type: "Info")
		pictureInPictureStopIsRestore = true
		completionHandler(true)
	}

	func pipControllerPlay(_ controller: PiPController) {
		print("PiP play requested")
		requestPlaying(true)
	}

	func pipControllerPause(_ controller: PiPController) {
		print("PiP pause requested")
		requestPlaying(false)
	}

	func pipController(_ controller: PiPController, skipByInterval interval: CMTime) {
		let seconds = CMTimeGetSeconds(interval)
		print("PiP skip by interval: \(seconds)")
		requestSeek(by: seconds)
	}

	func pipControllerIsPlaying(_ controller: PiPController) -> Bool {
		// Use intended state to ignore transient pauses during seeking
		return intendedPlayState
	}

	func pipControllerDuration(_ controller: PiPController) -> Double {
		return getDuration()
	}

	func pipControllerCurrentPosition(_ controller: PiPController) -> Double {
		return getCurrentPosition()
	}
}
