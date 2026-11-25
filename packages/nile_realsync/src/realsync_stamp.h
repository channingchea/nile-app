// RealSync capture stamps — shared by iOS, macOS and Android.
//
// Every camera and audio publisher stamps each encoded frame with its wall
// clock; every viewer reads the stamp back as the frame arrives. With each
// device's offset to the server clock (ClockReporter), a viewer knows how old
// each stream's content is, so it can hold the newer one back.
//
// Wire format: LiveKit's own "packet trailer" (client-sdk-js
// src/frameMetadata/frameMetadata.ts, rust-sdks webrtc-sys packet_trailer.cpp),
// so a future LiveKit Flutter SDK — or a web viewer — reads the same bytes.
//   video: trailer appended to the frame (decoders ignore it; viewers strip it)
//   audio: LiveKit has no audio format, so the same trailer rides in Opus
//          packet padding (RFC 6716 §3.2.5), which every decoder skips.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace nile_rs {

// ── Wire format (pure) ──────────────────────────────────────────────────────

std::vector<uint8_t> BuildTrailer(uint64_t user_timestamp_us);

/// Length of a valid trailer at the very end of the data (0 when none), and
/// its timestamp.
size_t ParseTrailer(const uint8_t* data, size_t size, uint64_t* user_timestamp_us);

/// Opus code-0 packet → code-3 (one CBR frame) carrying `pad` as padding.
bool OpusWithPadding(const uint8_t* data, size_t size, const std::vector<uint8_t>& pad,
                     std::vector<uint8_t>* out);

/// RFC 2198 RED packet: pads the primary (last) block, leaves the rest.
bool RedWithPadding(const uint8_t* data, size_t size, const std::vector<uint8_t>& pad,
                    std::vector<uint8_t>* out);

/// Median of the ages recorded at or after `since_us`; false when none.
bool MedianAge(const std::vector<std::pair<int64_t, int64_t>>& arrivals, int64_t since_us,
               double* median_ms, int* count);

// ── Live transformers (libwebrtc ABI) ───────────────────────────────────────

enum class Media { kVideo = 0, kAudio = 1 };

/// Implemented per platform: is `p` inside the loaded libwebrtc image?
bool InWebRtcImage(const void* p);

/// webrtc::RtpSenderInterface / RtpReceiverInterface vtable slots for
/// SetFrameTransformer (M144). Platforms prove them before calling.
constexpr int kSenderSetFrameTransformer = 22;
constexpr int kReceiverSetFrameTransformer = 18;

/// Stamp every frame leaving `native_sender`. PTs come from the sender's
/// negotiated codecs (-1 when absent); audio frames of other types pass.
/// Audio without a known Opus type isn't installed (false): retry later.
bool StampSender(const std::string& id, void* native_sender, Media media, int opus_pt,
                 int red_pt);

/// Read (and for video strip) stamps arriving at `native_receiver`.
bool ReadReceiver(const std::string& id, void* native_receiver, Media media);

/// Stop stamping/reading and drop the readings. (The transformer stays
/// installed as a pass-through: libwebrtc can't take a null one.)
void Forget(const std::string& id);

/// Arrival age (this device's wall clock − sender's stamp), median over the
/// frames that arrived in the last `window_ms`. False when none did.
bool ReceiverAge(const std::string& id, int window_ms, double* median_ms, int* count);

/// Frames a sender has stamped so far (-1 if unknown id). For self-checks.
int64_t StampedCount(const std::string& id);

}  // namespace nile_rs
