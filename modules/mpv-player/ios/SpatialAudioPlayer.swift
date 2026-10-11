import AVFoundation
#if os(tvOS)
import SpatialAudioBridge
import SpatialAudioPlayback
#endif

/// Where SpatialAudioBridge finds a stream's video and its Atmos track.
struct SpatialAudioSource {
	/// Jellyfin's stream-copy HLS master; its audio is replaced by APAC.
	let videoMaster: URL
	/// The track's position among the file's audio tracks.
	let audioTrackOrdinal: Int
}

/// Callbacks arrive on the main thread.
protocol SpatialAudioPlayerDelegate: AnyObject {
	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didUpdatePosition position: Double, duration: Double)
	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didChangePause isPaused: Bool)
	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didChangeLoading isLoading: Bool)
	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didBecomeReadyWith hdrMode: HDRMode, fps: Double)
	func spatialAudioPlayerDidReachEnd(_ player: SpatialAudioPlayer)
	/// The stream failed mid-playback, such as on unsupported metadata partway
	/// through: the host plays on through its usual audio path.
	func spatialAudioPlayer(_ player: SpatialAudioPlayer, didFailAt position: Double)
}

/// Plays a TrueHD Atmos or DTS:X track as Apple spatial audio (APAC) through
/// AVPlayer, with Jellyfin's stream-copy HLS video. mpv decodes these tracks
/// to PCM, which drops the Atmos objects. SpatialAudioBridge converts the track
/// on demand from the direct-play file and serves it beside the video over
/// loopback HLS; AtmosOutputActivator switches the HDMI output to Atmos.
///
/// Main thread only. Created by `start`, released by `stop()`.
final class SpatialAudioPlayer {
	private(set) weak var delegate: SpatialAudioPlayerDelegate?
	/// Hosts put this in their layer tree; AVPlayer draws the subtitles into it.
	let layer: AVPlayerLayer

	private let player: AVPlayer
	private let masterURL: URL
	private let teardown: @MainActor () -> Void
	private var observations: [NSKeyValueObservation] = []
	private var notificationObservers: [NSObjectProtocol] = []
	private var timeObserver: Any?
	private var stallTimer: Timer?
	private var lastStatus: AVPlayer.TimeControlStatus?
	private var waitingSince: Date?
	/// The latest seek target until the seek completes, so a stall recovery
	/// resumes there rather than where playback stopped.
	private var pendingSeek: Double?
	/// 1-based subtitle rendition, re-applied to every item.
	private var subtitle: Int?
	private var isStopped = false

	/// AVPlayer can stop requesting media after rapid seeks, when Jellyfin
	/// aborts a segment or a connection drops, and never recovers on its own.
	/// Seeks on long-GOP titles took up to 15 s to resume, so 20 s of waiting
	/// means it is stuck. See SpatialAudioBridge's troubleshooting guide.
	private static let stallTimeout: TimeInterval = 20

	private init(player: AVPlayer, masterURL: URL, teardown: @escaping @MainActor () -> Void) {
		self.player = player
		self.masterURL = masterURL
		self.teardown = teardown
		layer = AVPlayerLayer(player: player)
		layer.videoGravity = .resizeAspect
		// Subtitles follow the user's pick, not the system caption preference.
		player.appliesMediaSelectionCriteriaAutomatically = false
	}

	#if os(tvOS)
	/// Opens the file and converts the segment at `position` before
	/// returning, so a track the library cannot render throws here and the
	/// host keeps its usual audio path.
	@available(tvOS 26, *)
	@MainActor
	static func start(
		source: SpatialAudioSource,
		file url: URL,
		headers: [String: String],
		at position: Double
	) async throws -> SpatialAudioPlayer {
		let file = try await MatroskaFile.open(HTTPByteSource(url: url, headers: headers))
		guard file.audioTracks.indices.contains(source.audioTrackOrdinal) else {
			throw SpatialAudioError.source("The file has no audio track \(source.audioTrackOrdinal)")
		}
		var options = APACStream.Options()
		// Jellyfin adds transcoding variants for HDR titles, which AVPlayer
		// switches to when a segment is slow.
		options.includesVideoVariant = { $0.query?.contains("AllowVideoStreamCopy=true") == true }
		let start = CMTime(seconds: position, preferredTimescale: 600)
		let stream = try await APACStream.start(
			file: file, track: file.audioTracks[source.audioTrackOrdinal],
			videoMaster: source.videoMaster, startTime: start, options: options)
		guard let master = stream.masterPlaylistURL else {
			await stream.stop()
			throw SpatialAudioError.source("The stream has no video master")
		}

		let player = AVPlayer()
		// The master offers only the APAC rendition.
		let atmos = AtmosOutputActivator()
		atmos.attach(to: player)
		let spatial = SpatialAudioPlayer(player: player, masterURL: master) {
			atmos.detach()
			Task { await stream.stop() }
		}
		player.replaceCurrentItem(with: AVPlayerItem(url: master))
		await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
		Logger.shared.log(
			"Spatial audio: playing \(stream.track.codecID) track \(stream.track.number) as APAC",
			type: "Info")
		return spatial
	}
	#endif

	/// Starts reporting to `delegate`, beginning with the current state.
	func report(to delegate: SpatialAudioPlayerDelegate) {
		self.delegate = delegate
		observe()
	}

	func stop() {
		guard !isStopped else { return }
		isStopped = true
		observations.forEach { $0.invalidate() }
		notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
		if let timeObserver { player.removeTimeObserver(timeObserver) }
		stallTimer?.invalidate()
		player.replaceCurrentItem(with: nil)
		layer.removeFromSuperlayer()
		MainActor.assumeIsolated(teardown)
	}

	// MARK: - Transport

	var isPaused: Bool { player.timeControlStatus == .paused }
	var position: Double { player.currentTime().seconds.finiteOrZero }

	func play() { player.play() }

	func pause() { player.pause() }

	func seek(to position: Double) {
		pendingSeek = position
		player.seek(
			to: CMTime(seconds: position, preferredTimescale: 600),
			toleranceBefore: .zero, toleranceAfter: .zero
		) { [weak self] finished in
			guard finished else { return }
			DispatchQueue.main.async { self?.pendingSeek = nil }
		}
	}

	func setSpeed(_ speed: Double) {
		// Only ever created on tvOS 26; the pod still builds for 15.1.
		if #available(iOS 16, tvOS 16, *) { player.defaultRate = Float(speed) }
		if player.rate != 0 { player.rate = Float(speed) }
	}

	func setMuted(_ muted: Bool) {
		player.isMuted = muted
	}

	/// 1-based position among the master's subtitle renditions, nil for none.
	func selectSubtitle(_ rendition: Int?) {
		subtitle = rendition
		applySubtitle()
	}

	func technicalInfo() -> [String: Any] {
		var info: [String: Any] = ["audioCodec": "apac"]
		if let size = player.currentItem?.presentationSize, size.width > 0 {
			info["videoWidth"] = Int(size.width)
			info["videoHeight"] = Int(size.height)
		}
		return info
	}

	// MARK: - Observation

	private func observe() {
		observations = [
			player.observe(\.timeControlStatus, options: [.initial]) { [weak self] _, _ in
				DispatchQueue.main.async { self?.timeControlStatusChanged() }
			},
			player.observe(\.currentItem?.status, options: [.initial]) { [weak self] _, _ in
				DispatchQueue.main.async { self?.itemStatusChanged() }
			},
		]
		timeObserver = player.addPeriodicTimeObserver(
			forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
		) { [weak self] time in
			guard let self, let item = self.player.currentItem else { return }
			self.delegate?.spatialAudioPlayer(
				self, didUpdatePosition: time.seconds.finiteOrZero,
				duration: item.duration.seconds.finiteOrZero)
		}
		notificationObservers = [
			NotificationCenter.default.addObserver(
				forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
			) { [weak self] note in
				guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
				self.delegate?.spatialAudioPlayerDidReachEnd(self)
			},
			NotificationCenter.default.addObserver(
				forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
			) { [weak self] note in
				guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
				self.fail("\(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] ?? "unknown error")")
			},
		]
		stallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			self?.recoverIfStalled()
		}
	}

	private func timeControlStatusChanged() {
		guard !isStopped else { return }
		let status = player.timeControlStatus
		let previous = lastStatus
		lastStatus = status
		let isWaiting = status == .waitingToPlayAtSpecifiedRate
		waitingSince = isWaiting ? (waitingSince ?? Date()) : nil
		// The first report states both, whatever the host assumed meanwhile.
		if previous == nil || (previous == .paused) != (status == .paused) {
			delegate?.spatialAudioPlayer(self, didChangePause: status == .paused)
		}
		if previous == nil || (previous == .waitingToPlayAtSpecifiedRate) != isWaiting {
			delegate?.spatialAudioPlayer(self, didChangeLoading: isWaiting)
		}
	}

	private func itemStatusChanged() {
		guard !isStopped, let item = player.currentItem else { return }
		switch item.status {
		case .readyToPlay:
			Task { @MainActor [weak self] in await self?.itemBecameReady(item) }
		case .failed:
			fail(item.error.map { "\($0)" } ?? "unknown error")
		default:
			break
		}
	}

	@MainActor
	private func itemBecameReady(_ item: AVPlayerItem) async {
		let variants = try? await (item.asset as? AVURLAsset)?.load(.variants)
		guard !isStopped, item === player.currentItem else { return }
		applySubtitle()
		let video = variants?.first?.videoAttributes
		let hdrMode: HDRMode
		switch video?.videoRange {
		case .pq?:
			hdrMode = video?.codecTypes.contains(kCMVideoCodecType_DolbyVisionHEVC) == true
				? .dolbyVision : .hdr10
		case .hlg?:
			hdrMode = .hlg
		default:
			hdrMode = .sdr
		}
		delegate?.spatialAudioPlayer(self, didBecomeReadyWith: hdrMode, fps: video?.nominalFrameRate ?? 0)
	}

	private func applySubtitle() {
		guard let item = player.currentItem, item.status == .readyToPlay else { return }
		let subtitle = subtitle
		Task { @MainActor [weak self] in
			guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
				  let self, !self.isStopped, item === self.player.currentItem else { return }
			let option = subtitle.flatMap { group.options.indices.contains($0 - 1) ? group.options[$0 - 1] : nil }
			item.select(option, in: group)
		}
	}

	private func fail(_ reason: String) {
		guard !isStopped else { return }
		Logger.shared.log("Spatial audio: playback failed, \(reason)", type: "Error")
		delegate?.spatialAudioPlayer(self, didFailAt: position)
	}

	private func recoverIfStalled() {
		guard !isStopped, let waitingSince,
			  Date().timeIntervalSince(waitingSince) > Self.stallTimeout else { return }
		let resume = pendingSeek ?? position
		Logger.shared.log("Spatial audio: recovering a stalled item at \(Int(resume)) s", type: "Warn")
		self.waitingSince = Date()
		player.replaceCurrentItem(with: AVPlayerItem(url: masterURL))
		seek(to: resume)
		player.play()
	}
}

private extension Double {
	var finiteOrZero: Double { isFinite ? self : 0 }
}
