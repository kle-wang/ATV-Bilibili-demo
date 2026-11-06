//
//  VideoPlayerViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import Combine
import Kingfisher
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct PlayInfo: Hashable {
    var aid: Int
    var cid: Int? = 0
    var epid: Int? = 0 // 港澳台解锁需要
    var seasonId: Int? = 0 // 番剧 season_id
    var ctime: Int? = 0
    var subType: Int? = nil // 0: 普通视频 1：番剧 2：电影 3：纪录片 4：国创 5：电视剧 7：综艺
    var lastPlayCid: Int?
    var playTimeInSecond: Int?
    var title: String?
    var ownerName: String?
    var coverURL: URL?

    var isCidVaild: Bool {
        return cid ?? 0 > 0
    }

    var isBangumi: Bool {
        return epid ?? 0 > 0 || seasonId ?? 0 > 0
    }

    var sequenceKey: String {
        "\(aid)-\(cid ?? 0)-\(epid ?? 0)-\(seasonId ?? 0)"
    }

    var contentIdentity: String {
        if let epid, epid > 0 { return "epid-\(epid)" }
        if let seasonId, seasonId > 0 { return "season-\(seasonId)" }
        return "aid-\(aid)"
    }

    var contextKey: PlayContextKey {
        PlayContextKey(aid: aid,
                       cid: cid ?? 0,
                       epid: epid ?? 0,
                       seasonId: seasonId ?? 0)
    }
}

enum VideoPlayerMode {
    case regular
    case preview
    case feedFlow
}

@MainActor
final class VideoSequenceProvider {
    private(set) var playSeq: [PlayInfo]
    private(set) var currentIndex: Int
    private(set) var temporaryOverrides = [PlayInfo]()
    private let preloadThreshold: Int
    var onNeedMore: (() async -> Void)?

    init(seq: [PlayInfo], currentIndex: Int = 0, preloadThreshold: Int = 8) {
        playSeq = seq.uniqued()
        self.currentIndex = max(0, min(currentIndex, max(playSeq.count - 1, 0)))
        self.preloadThreshold = preloadThreshold
    }

    var count: Int {
        playSeq.count
    }

    var hasPrevious: Bool {
        currentIndex > 0
    }

    var hasNext: Bool {
        currentIndex + 1 < playSeq.count
    }

    func current() -> PlayInfo? {
        if let temporary = temporaryOverrides.last {
            return temporary
        }
        guard playSeq.indices.contains(currentIndex) else { return nil }
        return playSeq[currentIndex]
    }

    func setCurrentIndex(_ index: Int) {
        guard playSeq.indices.contains(index) else { return }
        clearTemporaryOverrides()
        currentIndex = index
    }

    func reset() {
        clearTemporaryOverrides()
        currentIndex = 0
    }

    func append(_ seq: [PlayInfo]) {
        var existing = Set(playSeq.map(\.sequenceKey))
        let newItems = seq.filter { existing.insert($0.sequenceKey).inserted }
        playSeq.append(contentsOf: newItems)
    }

    func peekPrevious() -> PlayInfo? {
        guard hasPrevious else { return nil }
        return playSeq[currentIndex - 1]
    }

    func peekNext() -> PlayInfo? {
        guard hasNext else { return nil }
        return playSeq[currentIndex + 1]
    }

    func peekNext(count: Int) -> [PlayInfo] {
        guard count > 0, hasNext else { return [] }
        let upper = min(playSeq.count - 1, currentIndex + count)
        return Array(playSeq[(currentIndex + 1)...upper])
    }

    func neighborItems(radius: Int) -> [PlayInfo] {
        guard !playSeq.isEmpty else { return temporaryOverrides.uniqued() }
        let lower = max(0, currentIndex - radius)
        let upper = min(playSeq.count - 1, currentIndex + radius)
        return ([current()].compactMap { $0 } + Array(playSeq[lower...upper])).uniqued()
    }

    func pushTemporary(_ playInfo: PlayInfo) {
        temporaryOverrides.append(playInfo)
    }

    func clearTemporaryOverrides() {
        temporaryOverrides.removeAll()
    }

    func movePrevious() -> PlayInfo? {
        guard hasPrevious else { return nil }
        clearTemporaryOverrides()
        currentIndex -= 1
        return playSeq[currentIndex]
    }

    func moveNext() async -> PlayInfo? {
        await prefetchMoreIfNeeded()
        guard hasNext else { return nil }
        clearTemporaryOverrides()
        currentIndex += 1
        await prefetchMoreIfNeeded()
        return playSeq[currentIndex]
    }

    func prefetchMoreIfNeeded() async {
        guard count - currentIndex - 1 < preloadThreshold else { return }
        await onNeedMore?()
    }
}

class VideoPlayerViewController: CommonPlayerViewController {
    enum AutoTriggeredInfoAction: String {
        case previous
        case next

        init?(title: String) {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTitle.contains("上一条") {
                self = .previous
            } else if trimmedTitle.contains("下一条") {
                self = .next
            } else {
                return nil
            }
        }
    }

    var data: VideoDetail? {
        didSet { viewModel.useInitialVideoDetail(data) }
    }

    var sequenceProvider: VideoSequenceProvider?
    var onLoadFailure: ((String) -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var onPlayInfoChanged: ((PlayInfo) -> Void)?
    var onDismissWithPlayInfo: ((PlayInfo) -> Void)?

    private let playMode: VideoPlayerMode
    private let playContextCache: PlayContextCache?
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private let previewMuted: Bool
    private let viewModel: VideoPlayerViewModel
    private var cancelable = Set<AnyCancellable>()
    private var neighborPreloadTask: Task<Void, Never>?
    private var currentRetryKey: String
    private var hasRetriedCurrentItem = false
    private var isStopping = false
    private var pendingAutoTriggeredInfoActionKey: String?

    init(playInfo: PlayInfo,
         playMode: VideoPlayerMode = .regular,
         playContextCache: PlayContextCache? = nil,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil,
         previewMuted: Bool = true,
         startTimeOverride: Int? = nil)
    {
        self.playMode = playMode
        self.playContextCache = playContextCache
        self.mediaWarmupManager = mediaWarmupManager
        self.previewMuted = previewMuted
        viewModel = VideoPlayerViewModel(playInfo: playInfo,
                                         playMode: playMode,
                                         playContextCache: playContextCache,
                                         mediaWarmupManager: mediaWarmupManager,
                                         previewMuted: previewMuted,
                                         startTimeOverride: startTimeOverride)
        currentRetryKey = playInfo.sequenceKey
        super.init(nibName: nil, bundle: nil)
        if playMode == .preview {
            showsPlaybackControls = false
            allowsPictureInPicturePlayback = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentPlayInfo: PlayInfo {
        viewModel.currentPlayInfo
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.sequenceProvider = sequenceProvider
        viewModel.currentTimeProvider = { [weak self] in
            self?.currentPlaybackTimeInSeconds()
        }
        viewModel.onPlayInfoChanged = { [weak self] info in
            self?.handlePlayInfoChanged(info)
        }
        viewModel.onShowDetail = { [weak self] info in
            self?.showDetail(for: info)
        }
        viewModel.loadResult.receive(on: DispatchQueue.main).sink { [weak self] result in
            switch result {
            case let .failure(err):
                self?.handleLoadFailure(message: err)
            case let .success(plugins):
                self?.neighborPreloadTask?.cancel()
                self?.removeAllPlugins()
                plugins.forEach { self?.addPlugin(plugin: $0) }
                self?.neighborPreloadTask = Task { [weak self] in
                    await self?.viewModel.preloadNeighborsIfNeeded()
                    // 当前视频先缓冲够，再逐条预缓冲后面几条，避免抢当前视频的带宽
                    guard self?.playMode == .feedFlow else { return }
                    guard await self?.waitForCurrentPlaybackBuffered() == true else { return }
                    await self?.viewModel.prebufferUpcoming()
                }
            }
        }.store(in: &cancelable)

        if playMode == .regular {
            viewModel.onExit = { [weak self] in
                self?.dismiss(animated: true)
            }
        }

        if playMode == .feedFlow {
            installFeedFlowRemoteControls()

            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleInfoActionFocusedNotification(_:)),
                                                   name: UICollectionViewCell.infoActionFocusedNotification,
                                                   object: nil)
            if #available(tvOS 11.0, *) {
                NotificationCenter.default.addObserver(self,
                                                       selector: #selector(handleSystemFocusUpdate(_:)),
                                                       name: UIFocusSystem.didUpdateNotification,
                                                       object: nil)
            }
        }

        viewModel.load()
    }

    override func viewDidDisappear(_ animated: Bool) {
        let isExiting = isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true
        let dismissPlayInfo = playMode == .feedFlow ? viewModel.currentPlayInfo : nil
        super.viewDidDisappear(animated)
        guard isExiting else { return }
        if playMode == .feedFlow {
            if let dismissPlayInfo {
                onDismissWithPlayInfo?(dismissPlayInfo)
            }
        }
        stopAsyncWork()
    }

    override func stopPlayback() {
        stopAsyncWork()
        super.stopPlayback()
    }

    override func playerDidStart(player: AVPlayer) {
        switch playMode {
        case .preview:
            onPlaybackStarted?()
        case .feedFlow, .regular:
            break
        }
    }

    override func playerDidStall(player: AVPlayer) {
        // 卡顿由 BVideoPlayPlugin 原位恢复（保留播放进度）；这里不再整条重载，
        // 否则短暂缓冲见底就会让视频从头开始播放。
    }

    override func playerDidFail(player: AVPlayer) {
        guard playMode == .feedFlow else {
            super.playerDidFail(player: player)
            return
        }
        attemptRetryOrShowRecovery(message: "当前视频加载失败，请选择重试或切换下一条。")
    }

    private func handlePlayInfoChanged(_ info: PlayInfo) {
        neighborPreloadTask?.cancel()
        neighborPreloadTask = nil
        if currentRetryKey != info.sequenceKey {
            currentRetryKey = info.sequenceKey
            hasRetriedCurrentItem = false
        }
        pendingAutoTriggeredInfoActionKey = nil
        onPlayInfoChanged?(info)
    }

    private func stopAsyncWork() {
        guard !isStopping else { return }
        isStopping = true
        chromeVisibilityTimer?.invalidate()
        chromeVisibilityTimer = nil
        coverWatchTimer?.invalidate()
        coverWatchTimer = nil
        neighborPreloadTask?.cancel()
        neighborPreloadTask = nil
        viewModel.cancelLoading()
        cancelable.removeAll()
        Task { [mediaWarmupManager] in
            await mediaWarmupManager?.cancelAll()
        }
    }

    private func handleLoadFailure(message: String) {
        switch playMode {
        case .preview:
            onLoadFailure?(message)
        case .feedFlow:
            attemptRetryOrShowRecovery(message: message)
        case .regular:
            showErrorAlertAndExit(message: message)
        }
    }

    private func attemptRetryOrShowRecovery(message: String) {
        guard !hasRetriedCurrentItem else {
            showFeedFlowRecoveryAlert(message: message)
            return
        }
        hasRetriedCurrentItem = true
        viewModel.retryCurrent()
    }

    private func showFeedFlowRecoveryAlert(message: String) {
        let alert = UIAlertController(title: "播放异常", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.hasRetriedCurrentItem = true
            self?.viewModel.retryCurrent()
        })
        alert.addAction(UIAlertAction(title: "下一条", style: .default) { [weak self] _ in
            Task { [weak self] in
                if await self?.viewModel.playNextFromSequence() == false {
                    self?.dismiss(animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
    }

    private func showDetail(for info: PlayInfo) {
        guard playMode != .preview else { return }
        let detailVC: VideoDetailViewController
        if let seasonId = info.seasonId, seasonId > 0 {
            detailVC = VideoDetailViewController.create(seasonId: seasonId)
        } else {
            detailVC = VideoDetailViewController.create(aid: info.aid, cid: info.cid, epid: info.epid)
        }
        detailVC.present(from: self, direatlyEnterVideo: false)
    }

    /// 等当前视频缓冲到 4s 以上（或已播放 20s 仍不足时放弃）。返回 false 表示被取消或条件不满足。
    private func waitForCurrentPlaybackBuffered() async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            if let item = currentPlayer?.currentItem,
               item.status == .readyToPlay,
               let range = item.loadedTimeRanges.first?.timeRangeValue
            {
                let buffered = range.start.seconds + range.duration.seconds - item.currentTime().seconds
                if buffered.isFinite, buffered >= 4 { return true }
            }
            if ProcessInfo.processInfo.systemUptime - start > 20 {
                Logger.info("[prebuffer] 当前视频 20s 内未缓冲到 4s，跳过预缓冲")
                return false
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // MARK: - 沉浸式模式遥控器

    //
    // 使用系统原生信息条（AVKit 控制条），按键归属按它是否显示来分配：
    //   · 信息条未显示：AVKit 的控制条处于关闭状态（showsPlaybackControls = false），按键由这里处理——
    //     ↑/↓ 切换上一条/下一条；OK、←/→、播放键 打开系统信息条（←/→ 同时快退/快进 10s，播放键同时暂停/继续）；
    //     返回键 退出播放。
    //   · 信息条显示中：开启 AVKit 控制条，所有按键交给系统，正常操作进度、相关视频、播放暂停等。
    // 信息条显示/隐藏由 AVPlayerViewControllerDelegate 的 willTransitionToVisibilityOfTransportBar 回调告知，
    // 隐藏后关闭控制条、把按键收回。

    private var isSystemChromeEnabled = true
    private var immersiveRecognizers = [UIGestureRecognizer]()
    private var remoteObserver: RemoteInteractionObserver?
    private var chromeVisibilityTimer: Timer?
    private var chromeEnabledAt = Date.distantPast
    private var chromeEverSeenVisible = false
    private let seekStep: Double = 10

    private func installFeedFlowRemoteControls() {
        setSystemChromeEnabled(false)
        // 首个视频加载期间也先显示封面，避免黑屏
        if let url = currentPlayInfo.coverURL {
            loadingCoverView.kf.setImage(with: url)
            loadingCoverView.alpha = 1
            startCoverWatch()
        }

        addImmersivePress(.upArrow, action: #selector(handleUpPress))
        addImmersivePress(.downArrow, action: #selector(handleDownPress))
        addImmersivePress(.select, action: #selector(handleSelectPress))
        addImmersivePress(.leftArrow, action: #selector(handleLeftPress))
        addImmersivePress(.rightArrow, action: #selector(handleRightPress))
        addImmersivePress(.playPause, action: #selector(handlePlayPausePress))
        addImmersivePress(.menu, action: #selector(handleMenuPress))
    }

    private func addImmersivePress(_ type: UIPress.PressType, action: Selector) {
        let recognizer = UITapGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
        immersiveRecognizers.append(recognizer)
    }

    private func setSystemChromeEnabled(_ enabled: Bool) {
        guard isSystemChromeEnabled != enabled else { return }
        isSystemChromeEnabled = enabled
        setPlaybackControlsEnabled(enabled)
        chromeVisibilityTimer?.invalidate()
        chromeVisibilityTimer = nil
        pendingChromeRelease = false
        if enabled {
            chromeEnabledAt = Date()
            chromeEverSeenVisible = false
            chromeVisibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkSystemChromeVisibility()
                }
            }
        }
        Logger.info("[FeedFlow] 系统信息条 \(enabled ? "接管按键" : "收起，↑↓ 切换")")
    }

    /// 打开系统信息条。AVKit 只在暂停或用户交互时显示控制条；播放中就短暂暂停再续播，让它显示出来
    private func revealSystemChrome(keepPaused: Bool = false) {
        setSystemChromeEnabled(true)
        guard let player = currentPlayer, player.rate > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak player] in
            player?.pause()
            guard !keepPaused else { return }
            // 暂停只是为了让 AVKit 显示控制条，尽量短，减少画面停顿
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak player] in
                player?.play()
            }
        }
    }

    /// 系统信息条显示/隐藏的官方回调（动画结束后调用）。隐藏后收回按键，↑↓ 恢复为切换视频。
    override func transportBarVisibilityWillChange(visible: Bool) {
        guard playMode == .feedFlow else { return }
        Logger.info("[FeedFlow] 系统信息条\(visible ? "显示" : "隐藏")")
        if visible {
            chromeEverSeenVisible = true
            pendingChromeRelease = false
        } else if isSystemChromeEnabled {
            if isFocusOnVideoSurface(UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView) {
                setSystemChromeEnabled(false)
            } else {
                // 焦点还在相关视频/菜单面板里，等它回到画面再收回按键
                pendingChromeRelease = true
            }
        }
    }

    private var pendingChromeRelease = false

    private func isFocusOnVideoSurface(_ focused: UIView?) -> Bool {
        guard let focused else { return true }
        let name = NSStringFromClass(type(of: focused))
        return name.contains("AVFocusContainerView") || name.contains("AVPlayerViewControllerContainerView")
    }

    /// 兜底：打开后 3s 内系统信息条一直没显示出来，就收回按键
    private func checkSystemChromeVisibility() {
        guard isSystemChromeEnabled, !chromeEverSeenVisible, presentedViewController == nil else { return }
        guard Date().timeIntervalSince(chromeEnabledAt) > 3 else { return }
        Logger.info("[FeedFlow] 系统信息条 3s 未显示，收回按键")
        setSystemChromeEnabled(false)
    }

    @objc private func handleSelectPress() {
        // 暂停状态下按 OK 直接继续播放
        if let player = currentPlayer, player.rate == 0, player.currentItem != nil {
            Logger.info("[FeedFlow] OK：继续播放")
            player.play()
            return
        }
        Logger.info("[FeedFlow] OK：打开系统信息条")
        revealSystemChrome()
    }

    @objc private func handlePlayPausePress() {
        guard let player = currentPlayer else { return }
        if player.rate > 0 {
            // 暂停后 AVKit 会自己显示信息条
            setSystemChromeEnabled(true)
            player.pause()
        } else {
            player.play()
        }
    }

    @objc private func handleLeftPress() {
        seek(by: -seekStep)
    }

    @objc private func handleRightPress() {
        seek(by: seekStep)
    }

    private func seek(by delta: Double) {
        revealSystemChrome()
        guard let player = currentPlayer, let item = player.currentItem else { return }
        let current = item.currentTime().seconds
        guard current.isFinite else { return }
        var target = max(0, current + delta)
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            target = min(target, max(0, duration - 1))
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    @objc private func handleMenuPress() {
        dismiss(animated: true)
    }

    @objc private func handleUpPress() {
        guard let target = sequenceProvider?.peekPrevious() else { return }
        Logger.info("[FeedFlow] ↑ 切换至上一条")
        slideTransition(to: target, direction: .previous)
        Task { [weak self] in
            _ = await self?.viewModel.playPreviousFromSequence()
        }
    }

    @objc private func handleDownPress() {
        Logger.info("[FeedFlow] ↓ 切换至下一条")
        // 下一条可能还没加载到列表里（moveNext 会先拉更多），拿不到时只显示加载封面不做目标预览
        slideTransition(to: sequenceProvider?.peekNext(), direction: .next)
        Task { [weak self] in
            guard let self else { return }
            if await self.viewModel.playNextFromSequence() == false {
                self.hideLoadingCover(animated: true)
            }
        }
    }

    // MARK: - 抖音式上下滑动切换 + 封面占位

    //
    // 视频画面截图在 tvOS 上通常是黑的，所以滑动用封面图：先把当前视频的封面盖上并截图，
    // 再换成目标视频的封面，旧图滑出、新图滑入；新视频真正开始播放后封面淡出，避免加载期间黑屏。

    private lazy var loadingCoverView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = false
        imageView.alpha = 0
        view.addSubview(imageView)
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return imageView
    }()

    private weak var activeSlideSnapshot: UIView?
    private var coverWatchTimer: Timer?

    private func slideTransition(to target: PlayInfo?, direction: AutoTriggeredInfoAction) {
        // 连续快速切换：结束上一段动画，避免截图叠加、视图停在偏移位置
        activeSlideSnapshot?.removeFromSuperview()
        view.layer.removeAllAnimations()
        view.transform = .identity

        let cover = loadingCoverView
        view.bringSubviewToFront(cover)
        if let current = currentPlayInfo.coverURL {
            cover.kf.setImage(with: current)
        }
        cover.alpha = 1

        let snapshot = view.superview.flatMap { container -> UIView? in
            guard let snap = view.snapshotView(afterScreenUpdates: true) else { return nil }
            snap.frame = view.frame
            container.addSubview(snap)
            return snap
        }
        activeSlideSnapshot = snapshot

        cover.image = nil
        if let url = target?.coverURL {
            cover.kf.setImage(with: url)
        }
        startCoverWatch()

        guard let snapshot else { return }
        let height = view.bounds.height
        let offset = direction == .next ? height : -height
        view.transform = CGAffineTransform(translationX: 0, y: offset)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            snapshot.transform = CGAffineTransform(translationX: 0, y: -offset)
            self.view.transform = .identity
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    /// 等新视频真正开始播放（且已有画面）后淡出封面；最多等 20s，失败或卡住时由其他恢复逻辑接手。
    private func startCoverWatch() {
        coverWatchTimer?.invalidate()
        let deadline = Date().addingTimeInterval(20)
        coverWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let isPlaying = self.currentPlayer?.timeControlStatus == .playing
                    && (self.currentPlayer?.currentItem?.status == .readyToPlay)
                if isPlaying || Date() > deadline {
                    self.hideLoadingCover(animated: true)
                }
            }
        }
    }

    private func hideLoadingCover(animated: Bool) {
        coverWatchTimer?.invalidate()
        coverWatchTimer = nil
        guard loadingCoverView.alpha > 0 else { return }
        UIView.animate(withDuration: animated ? 0.25 : 0) {
            self.loadingCoverView.alpha = 0
        }
    }

    @available(tvOS 11.0, *)
    @objc private func handleSystemFocusUpdate(_ note: Notification) {
        guard playMode == .feedFlow,
              let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
              let nextView = context.nextFocusedView
        else { return }
        if pendingChromeRelease, isSystemChromeEnabled, isFocusOnVideoSurface(nextView) {
            pendingChromeRelease = false
            setSystemChromeEnabled(false)
        }

        installAVInfoPanelHookIfNeeded(for: nextView)
        #if DEBUG
            // 不再每次焦点变化都整棵 dump 视图树：主线程开销大，Debug 真机运行时明显拖慢界面
            Logger.debug("[FocusDiag] 焦点落在了类: \(type(of: nextView))")
        #endif
    }

    #if DEBUG
        private func dumpViewHierarchy(_ view: UIView, depth: Int) -> String {
            guard depth < 6 else { return "" }
            let indent = String(repeating: "  ", count: depth)
            var result = "\(indent)- \(type(of: view))"
            if let label = view as? UILabel {
                result += " text: '\(label.text ?? "")' attr: '\(label.attributedText?.string ?? "")'"
            } else if let btn = view as? UIButton {
                result += " title: '\(btn.title(for: .normal) ?? "")'"
            }
            result += "\n"
            for subview in view.subviews {
                result += dumpViewHierarchy(subview, depth: depth + 1)
            }
            return result
        }
    #endif

    private func installAVInfoPanelHookIfNeeded(for view: UIView) {
        guard containsAVInfoPanelHierarchy(from: view) else { return }
        guard AVInfoPanelCollectionViewThumbnailCellHook.start(),
              let title = extractInfoActionTitle(from: view)
        else { return }
        handleFocusedInfoAction(title: title)
    }

    private func containsAVInfoPanelHierarchy(from view: UIView) -> Bool {
        var currentView: UIView? = view
        var remainingDepth = 8

        while let ancestorView = currentView, remainingDepth > 0 {
            if NSStringFromClass(type(of: ancestorView)).contains("AVInfoPanel") {
                return true
            }
            remainingDepth -= 1
            currentView = ancestorView.superview
        }

        return false
    }

    private func extractInfoActionTitle(from view: UIView) -> String? {
        var currentView: UIView? = view
        var remainingDepth = 8

        while let candidate = currentView, remainingDepth > 0 {
            if let title = matchingInfoActionTitle(in: candidate, maxDepth: 0) {
                return title
            }
            let isActionContainer = candidate is UICollectionViewCell ||
                NSStringFromClass(type(of: candidate)).contains("AVInfoPanel")
            if isActionContainer,
               let title = matchingInfoActionTitle(in: candidate, maxDepth: 4)
            {
                return title
            }
            remainingDepth -= 1
            currentView = candidate.superview
        }
        return nil
    }

    private func matchingInfoActionTitle(in view: UIView, maxDepth: Int) -> String? {
        let titles: [String?]
        if let label = view as? UILabel {
            titles = [label.text, label.attributedText?.string, label.accessibilityLabel]
        } else if let button = view as? UIButton {
            titles = [button.title(for: .focused), button.title(for: .normal), button.accessibilityLabel]
        } else {
            titles = [view.accessibilityLabel]
        }
        if let title = titles.compactMap({ $0 }).first(where: { AutoTriggeredInfoAction(title: $0) != nil }) {
            return title
        }
        guard maxDepth > 0 else { return nil }
        for subview in view.subviews {
            if let title = matchingInfoActionTitle(in: subview, maxDepth: maxDepth - 1) {
                return title
            }
        }
        return nil
    }

    @objc private func handleInfoActionFocusedNotification(_ note: Notification) {
        guard let title = note.userInfo?["title"] as? String else { return }
        handleFocusedInfoAction(title: title)
    }

    private func handleFocusedInfoAction(title: String) {
        guard playMode == .feedFlow,
              let action = AutoTriggeredInfoAction(title: title)
        else { return }

        let actionKey = "\(currentPlayInfo.sequenceKey)::\(action.rawValue)"
        guard pendingAutoTriggeredInfoActionKey != actionKey else { return }
        pendingAutoTriggeredInfoActionKey = actionKey

        Task { [weak self] in
            guard let self else { return }
            let didTrigger: Bool
            switch action {
            case .previous:
                didTrigger = await self.viewModel.playPreviousFromSequence()
            case .next:
                didTrigger = await self.viewModel.playNextFromSequence()
            }
            if !didTrigger, self.pendingAutoTriggeredInfoActionKey == actionKey {
                self.pendingAutoTriggeredInfoActionKey = nil
            }
        }
    }
}

extension VideoPlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if immersiveRecognizers.contains(where: { $0 === gestureRecognizer }) {
            // 系统控制条开启时按键全部交还 AVKit
            return !isSystemChromeEnabled
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool
    {
        gestureRecognizer === remoteObserver || otherGestureRecognizer === remoteObserver
    }
}

/// 只观察、不拦截：在遥控器按键按下时回调（不计触摸板轻触，点按前总会先有触摸），随即失败，不影响任何其他手势与响应者。
final class RemoteInteractionObserver: UIGestureRecognizer {
    private let onInteraction: (UIPress.PressType) -> Void

    init(onInteraction: @escaping (UIPress.PressType) -> Void) {
        self.onInteraction = onInteraction
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = []
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        presses.forEach { onInteraction($0.type) }
        state = .failed
    }
}
