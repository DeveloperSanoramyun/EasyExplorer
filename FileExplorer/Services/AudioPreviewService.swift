//
//  AudioPreviewService.swift
//  FileExplorer
//
//  Lightweight inline "preview-listen" for audio files, so the user
//  can sample a track straight from the list without opening Quick
//  Look or the Preview pane. One shared AVAudioPlayer — starting a new
//  file stops the previous one, so only ever one preview plays at a
//  time. Views observe `playingURL` / `isPlaying` to render the right
//  play / pause glyph on each row.
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers
import Combine

@MainActor
final class AudioPreviewService: NSObject, ObservableObject {

    static let shared = AudioPreviewService()

    /// The URL currently loaded into the player (playing OR paused),
    /// or nil when nothing is loaded. Rows compare against this to
    /// show their play/pause state.
    @Published private(set) var playingURL: URL?
    /// True while audio is actively playing (false when paused/stopped).
    @Published private(set) var isPlaying: Bool = false

    private var player: AVAudioPlayer?

    /// Timestamp of the last play/pause tap. The list views read this to
    /// suppress the slow-second-click rename when the user actually
    /// tapped the row's ▶ control (which, being inside the row, also
    /// fires the row's selection gesture and would otherwise arm a
    /// phantom rename).
    private(set) var lastToggleAt: Date = .distantPast
    private var lastToggleURL: URL?

    /// True if the ▶ control of THIS row was tapped within the rename-
    /// arming window. Keyed by URL so tapping play on one file doesn't
    /// suppress a deliberate slow-click rename of a *different* file
    /// within the 0.8 s window.
    func recentlyToggled(_ url: URL) -> Bool {
        lastToggleURL == url && Date().timeIntervalSince(lastToggleAt) < 0.8
    }

    private override init() { super.init() }

    /// Returns true if `url` is something we can preview-play. Used by
    /// the views to decide whether to show a play button at all.
    static func isAudio(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        if let id = item.typeIdentifier, let ut = UTType(id) {
            return ut.conforms(to: .audio)
        }
        // Fall back to extension sniffing for files Spotlight hasn't
        // typed yet (e.g. freshly-copied results).
        let ext = item.url.pathExtension.lowercased()
        return ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac",
                "alac", "ogg", "opus", "wma"].contains(ext)
    }

    /// Toggle playback for `url`:
    ///   • not loaded  → load + play
    ///   • playing it  → pause
    ///   • paused on it→ resume
    func toggle(_ url: URL) {
        lastToggleAt = Date()
        lastToggleURL = url
        if playingURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        start(url)
    }

    /// Stop and unload — called when the file leaves the listing or
    /// the user navigates away, so we don't keep audio playing for a
    /// folder that's no longer visible.
    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        isPlaying = false
    }

    private func start(_ url: URL) {
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playingURL = url
            isPlaying = true
        } catch {
            // Unsupported codec / unreadable file — clear state so the
            // row resets to the plain play glyph rather than a stuck
            // "loading" look.
            player = nil
            playingURL = nil
            isPlaying = false
        }
    }
}

extension AudioPreviewService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Identity guard: if a NEW file started before this (old)
            // player's end-of-buffer callback was delivered, `self.player`
            // already points at the new player. Without the `===` check
            // the stale callback would null out the new playback and
            // leave the UI stuck on ▶.
            guard self.player === finished else { return }
            // Reached the end — reset so the row shows ▶ again and a
            // re-tap restarts from the top.
            self.isPlaying = false
            self.playingURL = nil
            self.player = nil
        }
    }
}

// MARK: - Reusable inline play/pause button

import SwiftUI

/// Small play/pause control for an audio row. Renders nothing for
/// non-audio items, so callers can drop it unconditionally into a row
/// and it only appears next to actual audio files.
struct AudioPlayButton: View {
    let item: FileItem
    @ObservedObject private var audio = AudioPreviewService.shared

    var body: some View {
        if AudioPreviewService.isAudio(item) {
            let isThis = audio.playingURL == item.url
            let playing = isThis && audio.isPlaying
            Button {
                audio.toggle(item.url)
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle")
                    .foregroundStyle(isThis ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(playing ? "Pause preview" : "Play preview")
        }
    }
}
