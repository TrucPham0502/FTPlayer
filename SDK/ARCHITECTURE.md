# SDK source layout

`Sources` is organized by responsibility. These directories belong to the same
`FTPlayer` framework target; they are not separate Swift modules.

```text
Sources/
├── API/                       # FTPlayer, delegate, states and video-output protocol
│   ├── Configuration/         # Public load-control and decoding policy
│   └── Models/                # Public media information and cached ranges
├── Playback/                  # Playback orchestration and pending seek lifecycle
│   ├── Buffering/             # Packet/frame queues, frame pool, ring buffer
│   └── Timing/                # Playback clocks and display timing
├── Demux/                     # FFmpeg format context and cache AVIO adapter
│   ├── HLS/                   # VOD resource cache (media/maps/keys/ranges), master A/V selection
│   └── Models/                # Stream metadata and track descriptions
├── Decoding/
│   ├── Audio/                 # Audio packet decoding
│   ├── Frames/                # Decoded frame types and native pixel helper
│   └── Video/
│       ├── Conversion/        # Pixel conversion helpers
│       └── VideoToolbox/      # Hardware decoder contract, factory and codecs
├── Audio/                     # Audio session, graph and output nodes
├── Rendering/                 # Renderer view, Metal renderer and shader
├── Cache/                     # Disk store, session lifetime, timeline and worker
├── Networking/                # HTTP range loading and size probes
├── Diagnostics/               # SDK logging and diagnostics
├── Support/
│   ├── FFmpeg/                # Native error translation
│   └── Platform/              # Platform view/image adapters
└── FTPlayer.h                 # Framework umbrella header
```

## Placement rules

Public controls, configuration, state observation and delegate/output bindings
belong to the main thread. Engine and audio threads enter through
`PlaybackEventGate`, which validates engine identity before enqueueing and a
revision again on main. Stop/reopen invalidates queued events before teardown.
Audio format reads use a lock-protected snapshot, never a synchronous wait on main.
Seek progress already emitted on main updates state immediately so relative seeks
compose correctly; app progress notifications remain queued on main.

Video output is independent of views. `FTPlayerVideoOutput` receives a
`CVPixelBuffer` and its presentation position in seconds on the main queue.
The app creates and owns a consumer (a view or another object) and assigns it to
`player.videoOutput`. The player holds it weakly. `Rendering` provides optional
view utilities; playback does not reference them. Replace `setRenderer(view)` with
`player.videoOutput = view` when the view conforms to `FTPlayerVideoOutput`.
Use existing progress and media-info delegate callbacks for time and size updates.

- Put new files next to the responsibility they implement, rather than grouping
  everything that uses FFmpeg into one directory.
- Keep decoding separate from audio output and video rendering.
- Keep HTTP transport in `Networking`; disk/cache coordination belongs in `Cache`.
- Put playback timing and queue management under `Playback`.
- Reserve `Support` for shared infrastructure; feature-specific helpers stay with
  their feature.
- Match Xcode groups to physical directories. `project.yml` includes `Sources`
  recursively; the checked-in Xcode project must reference the same files.

## SOLID boundaries

- **Single responsibility:** delegate, state, public models and configuration have
  dedicated files. Disk storage, cache session lifetime and cached timeline indexing
  are separate types/files. `PlaybackSeekController` owns pending seek replacement,
  cancellation and completion, outside the decoder's packet loop.
  `PlaybackPreparationWorkflow` owns forward-only preparation transitions.
  `PlaybackLifecycleController` owns background/foreground and audio interruption
  policy; `PlaybackTelemetry` owns the diagnostic timer.
- **Open/closed and dependency inversion:** clock control uses `FTPlaybackClock`
  without downcasting to concrete clocks. Each implementation owns its pause, rate
  and seek behavior. `FTPlayerVideoOutput` exposes pixel buffers and presentation time; the app
  owns rendering. The player has no renderer reference or view binding API.
  The facade and its factory use `PlaybackEngine` (control/status contracts),
  `PlaybackAudioOutput` and `PlaybackCacheSession`; the facade receives these dependencies
  from its factory instead of constructing their implementations. Tests substitute an engine that is
  not an FTDecoder subclass.
- **Interface segregation:** `FTAudioManager` consumes the narrow
  `FTAudioFrameSource` contract. Video output no longer requires an unused audio
  callback. `CacheWorker` consumes injectable `HTTPStreamingLoading` instead of a
  concrete URLSession loader. `PlaybackComponentFactory` centralizes engine, audio
  and cache construction and can be injected into the player internally.
  Playlist document loading uses `HTTPDataLoading` in Networking, injected into
  the format context/HLS preparation path. Its response includes the final URL
  after redirects for relative resource resolution; manifest cache identity keeps
  the originally requested URL. HLS parsing and manifest caching stay
  in Demux. Apps can bind playback, progress and preparation observers separately;
  the legacy composite delegate remains a fallback for each unbound group.
- **Substitution:** clock implementations preserve paused positions and support the
  same control contract; regression tests exercise both through the protocol.
  Audio sources must provide nonblocking reads on the render thread. Renderer
  callbacks run on the main queue, and the app retains its renderer.

The framework remains a single module. Folder boundaries do not enforce imports.
`FTPlayer` is the public facade; `FTDecoder` coordinates packet, clock and decoder
work behind the engine contract. Public video output is a protocol, not a view
binding. Engine-specific inspection/downcasts are confined to integration tests.
At rates ≥4×, VSync presents the newest decoded picture already due, including
rate-change grace, preserving forward PTS within the seek epoch.
Decoded buffer duration at these sampled rates follows queued PTS coverage from
the presentation clock, rather than summing the original duration of the few
retained pictures. Catch-up preserves decoded pixel buffers for the next display
tick while flushing codec references; seek/Stop still clear the picture queue.
Decoder catch-up chooses the latest queued random-access packet in a bounded
window (up to 0.5 wall seconds behind and 0.1 ahead of the clock), advancing beyond
the stale input packet without crossing a seek marker. The small forward bound
prevents a far-future picture from waiting for the audio clock. When the packet
byte budget prevents reaching the startup/rebuffer time threshold, decoded media
can resume playback so consumption admits more packets; the RAM cap is unchanged.
Software video codec contexts use available CPU parallelism capped at four
threads before opening, bounding frame delay and reference-frame memory. Audio
contexts retain their existing settings. Codec source/binaries are unchanged.
For native MOV/MP4 H.264 and HEVC, a complete-frame FFmpeg parser with its own
unopened codec context verifies encoded random access. Confirmed disagreements
repair packet flags and the public demux index, including stale index entries
whose packet flags were already repaired by demux parsing. After a correction,
seeks within observed coverage may use a verified random-access DTS with ANY;
unseen ranges keep native lookup. The bounded index retains at most 4096 anchors.
Unknown parser results leave metadata untouched; HLS stays on its own path.
Corrupt packets and reads canceled by a pending seek do not update that index:
a successful short HTTP packet must not replace a full MOV sample's byte size.
An index repair requires both DTS and byte position to identify the packet;
MOV edit-list retiming can otherwise collide with a different indexed sample.
The repair preserves its original byte range, distance and other index flags.
Native HLS VOD seeks can reuse observed
video keyframe DTS anchors to avoid segment-origin rounding losing the first IDR.
For separate audio/video, anchors are normalized from the video's initial DTS to
the common origin before HLS applies rendition offsets. An explicit video stream
and one full timebase tick of preroll avoid microsecond round-trip loss.
The demux-thread index is capped at 4096 anchors. Reuse covers already read
media or nearby unread preroll bounded by the declared maximum segment
duration, configured buffer window and a 50-second cap; distant unseen ranges retain native segment lookup with one
declared segment of preroll (within the same bound), preserving reference frames
when rounded EXTINF durations drift from packet timestamps. A seek before
the first packet read seeds the index from the opened input, bounded to 512
packets/8 MiB and cancellable; normal startup performs no extra read. SDK preroll
keeps the public requested time. Live HLS stays on the native path. EOF
buffering wakeup and bounded native HTTP reconnection remain in place. This fix
does not require rebuilding or replacing FFmpeg.
Finite TS VOD discontinuities are represented as standalone HLS periods joined
by the existing concat demuxer. Each child keeps its original segment URLs,
key changes and media sequence (including sequence-derived IVs), while concat
normalizes timestamp origins. Independent files seek with a one-tick boundary
preroll; HLS children seek at the exact boundary so the preceding child is not
asked to seek beyond EOF. A master with one selected muxed rendition delegates
to the same timeline. Masters with external audio retain their native HLS
rendition timelines and shared cache path. Seek to zero reopens the prepared
cached description to retain initial reference pictures. A native first-segment
preroll uses the same reopen when DTS leads the common origin.
For prepared finite HLS, isolated video PTS outside a duration-derived range
with valid in-range DTS are marked unknown; FFmpeg can derive presentation timing,
and VT falls back to the real DTS when its callback CMTime is invalid. No URL
or sample-specific timestamp constants are used. Annex-B H.264 SPS/PPS changes
recreate the VT format/session using dimensions from the new parameter sets,
preserving delayed pictures and hardware decoding across ad boundaries.
Audio frames use a known best-effort timestamp, PTS or DTS. When a PES timestamps
only its first AAC frame, subsequent unknown timestamps advance from that anchor
by the decoded sample count and source sample rate. A real timestamp always
replaces the inferred next position, preserving gaps; seek flush clears the
anchor. Unanchored frames are not assigned an invented zero timestamp.
Audio PCM with a future timestamp after a real gap remains queued until its
consumption-clock time is due. The existing audio render path supplies silence
while the clock interpolates; input scheduling uses time before output latency
compensation, so a 16x gap cannot skip media time or apply the output delay twice.
Concat inputs enable standard `segment_time_metadata` at open and reopen. The
audio decoder clips resampled PCM to the decoded frame's `lavf.concatdec` period
bounds. A complete file extending beyond EXTINF cannot overlap the next period
and rewind the clock. Codec input/reference state is retained, and delayed audio
uses its own frame metadata rather than the latest submitted packet's bounds.
Audio EOF does not finish an item while video output remains. Its clock keeps
interpolating through a video-only tail, and normal pause/seek/rate gates remain
active until the remaining pictures have been consumed. Terminal checks also
wait for PCM currently owned by the render callback, not just an empty audio
queue, and use the audio try-lock to avoid racing frame handoff or seek reset.
VSync stops after finished and cannot replace the terminal time with an older
audio-tail interpolation value.
While a video seek target is pending, ordinary audio-clock catch-up does not
discard the video queue. Seek preroll owns those reference pictures and keeps
the final picture until EOF confirms a seek has entered an audio-only tail.
Lowering rate from at least 8x may re-seek only during stable, unpaused playback.
Taking a demux seek clears its pending request before its clock is committed;
the audio seek gate and both preroll targets must also be clear. Otherwise an
automatic rate-recovery seek can replace the user's final burst-seek target
with a preceding request's audio position. Rate and AudioUnit updates still
apply immediately while seeking or paused.
PCM before a pending seek is discarded at audio decode queue insertion, so a
long GOP cannot fill the 8 MiB read budget while rendering is buffering. Audio
render uses a nonblocking try-lock to serialize clock commits with seek
publication; a seek gate stays closed through demux reset. The facade separately
invalidates queued progress, video output and finish events from the preceding
seek epoch, including finish observer notifications already queued on main.
An accepted explicit seek clears the engine's finished state synchronously so
immediate Play keeps that target instead of starting replay at zero. The facade
also checks the engine's terminal state before requesting replay from a public
finished state whose buffering callbacks have not arrived yet. Ordinary
progress callbacks retain their captured values.
The first intersecting PCM frame after seek skips its pre-target samples using
an output offset, after removal from the duration-accounted queue. This preserves
queue bookkeeping and the published seek target without a render-thread copy.

Tests remain in `SDK/Tests`; vendor binaries and build scripts stay outside
`Sources`. The Demo uses the same public output and observer APIs as an app consumer.
