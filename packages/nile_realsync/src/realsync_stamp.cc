// RealSync capture stamps — see realsync_stamp.h.
//
// The frame transformer is written against libwebrtc's ABI, not its headers
// (the shipped WebRTC builds have none): our class lays out its virtuals in
// the same order as webrtc::FrameTransformerInterface, and libwebrtc objects
// are called through their vtable slots, all taken from the M144 headers
// (api/frame_transformer_interface.h, api/ref_count.h). The platforms prove
// the sender/receiver slots before installing; tool/rs_probe.mm proves the
// rest end to end against the real binary.
#include "realsync_stamp.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>

namespace nile_rs {

// ── Wire format ─────────────────────────────────────────────────────────────

namespace {
constexpr uint8_t kMagic[4] = {'L', 'K', 'T', 'S'};
constexpr uint8_t kTagTimestamp = 0x01;
constexpr size_t kEnvelope = 5;  // length byte + magic
}  // namespace

std::vector<uint8_t> BuildTrailer(uint64_t us) {
  // Every byte XORed with 0xFF so no H.264 start code can appear inside.
  std::vector<uint8_t> t{kTagTimestamp ^ 0xFF, 8 ^ 0xFF};
  for (int i = 7; i >= 0; --i) t.push_back(static_cast<uint8_t>(((us >> (i * 8)) & 0xFF) ^ 0xFF));
  t.push_back(static_cast<uint8_t>((t.size() + kEnvelope) ^ 0xFF));
  t.insert(t.end(), kMagic, kMagic + 4);
  return t;
}

size_t ParseTrailer(const uint8_t* d, size_t n, uint64_t* us) {
  if (!d || n < kEnvelope || std::memcmp(d + n - 4, kMagic, 4) != 0) return 0;
  const size_t len = d[n - kEnvelope] ^ 0xFF;
  if (len < kEnvelope || len > n) return 0;
  const uint8_t* tlv = d + n - len;
  const size_t tlv_len = len - kEnvelope;
  for (size_t pos = 0; pos + 2 <= tlv_len;) {
    const uint8_t tag = tlv[pos] ^ 0xFF, l = tlv[pos + 1] ^ 0xFF;
    pos += 2;
    if (pos + l > tlv_len) break;
    if (tag == kTagTimestamp && l == 8) {
      uint64_t v = 0;
      for (int i = 0; i < 8; ++i) v = (v << 8) | (tlv[pos + i] ^ 0xFF);
      *us = v;
      return len;
    }
    pos += l;
  }
  return 0;
}

bool OpusWithPadding(const uint8_t* d, size_t n, const std::vector<uint8_t>& pad,
                     std::vector<uint8_t>* out) {
  // Code 0 only (one frame; LiveKit sends 20 ms). Skip DTX/empty packets.
  if (!d || n <= 2 || (d[0] & 3) != 0 || pad.empty() || pad.size() > 254) return false;
  out->clear();
  out->reserve(n + 2 + pad.size());
  out->push_back(static_cast<uint8_t>((d[0] & 0xFC) | 3));  // TOC, code 3
  out->push_back(0x40 | 1);                                 // CBR, padding, 1 frame
  out->push_back(static_cast<uint8_t>(pad.size()));         // padding length
  out->insert(out->end(), d + 1, d + n);
  out->insert(out->end(), pad.begin(), pad.end());
  return true;
}

bool RedWithPadding(const uint8_t* d, size_t n, const std::vector<uint8_t>& pad,
                    std::vector<uint8_t>* out) {
  if (!d) return false;
  size_t i = 0, redundant = 0;
  while (i < n && (d[i] & 0x80)) {  // 4-byte headers of redundant blocks
    if (i + 4 > n) return false;
    redundant += ((d[i + 2] & 0x03) << 8) | d[i + 3];
    i += 4;
  }
  const size_t start = i + 1 + redundant;  // after the primary's 1-byte header
  if (i >= n || start >= n) return false;
  std::vector<uint8_t> primary;
  if (!OpusWithPadding(d + start, n - start, pad, &primary)) return false;
  out->assign(d, d + start);
  out->insert(out->end(), primary.begin(), primary.end());
  return true;
}

bool MedianAge(const std::vector<std::pair<int64_t, int64_t>>& arrivals, int64_t since_us,
               double* median_ms, int* count) {
  std::vector<int64_t> ages;
  for (const auto& [at, age] : arrivals) {
    if (at >= since_us) ages.push_back(age);
  }
  *count = static_cast<int>(ages.size());
  if (ages.empty()) return false;
  std::sort(ages.begin(), ages.end());
  const size_t m = ages.size() / 2;
  const double us = ages.size() % 2 ? ages[m] : (ages[m - 1] + ages[m]) / 2.0;
  *median_ms = us / 1000.0;
  return true;
}

// ── libwebrtc ABI ───────────────────────────────────────────────────────────

namespace {

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

template <typename Fn>
Fn Slot(const void* obj, int i) {
  return reinterpret_cast<Fn>((*reinterpret_cast<void* const* const*>(obj))[i]);
}

// RefCountInterface: 0 AddRef, 1 Release, 2/3 destructors.
void AddRef(void* o) { Slot<void (*)(const void*)>(o, 0)(o); }
void Release(void* o) { Slot<int (*)(const void*)>(o, 1)(o); }

// TransformableFrameInterface (no RefCountInterface base): 0/1 destructors,
// 2 GetData, 3 SetData, 4 GetPayloadType, 7 GetSsrc.
struct View {  // webrtc::ArrayView<const uint8_t>: {data, size}, trivially copyable
  const uint8_t* data;
  size_t size;
};
View GetData(void* f) { return Slot<View (*)(const void*)>(f, 2)(f); }
void SetData(void* f, const std::vector<uint8_t>& v) {
  Slot<void (*)(void*, View)>(f, 3)(f, View{v.data(), v.size()});
}
uint8_t GetPayloadType(void* f) { return Slot<uint8_t (*)(const void*)>(f, 4)(f); }
uint32_t GetSsrc(void* f) { return Slot<uint32_t (*)(const void*)>(f, 7)(f); }
void DeleteFrame(void* f) { Slot<void (*)(void*)>(f, 1)(f); }  // deleting destructor

// std::unique_ptr<TransformableFrameInterface> is passed either as the bare
// pointer (libc++ trivial-ABI unique_ptr) or as a pointer to it, depending on
// how libwebrtc was built. Told apart on the first frame: a frame's first word
// is its vtable, inside libwebrtc; a unique_ptr's first word is the frame.
std::atomic<int> g_unique_ptr_abi{0};  // 0 unknown, 1 bare pointer, 2 indirect

void* TakeFrame(void* arg) {
  int abi = g_unique_ptr_abi.load();
  if (abi == 0 && arg) {
    void* first = *static_cast<void**>(arg);
    if (InWebRtcImage(first)) abi = 1;
    else if (first && InWebRtcImage(*static_cast<void**>(first))) abi = 2;
    if (abi) g_unique_ptr_abi = abi;
  }
  if (abi == 1) return arg;
  if (abi == 2) {
    void** slot = static_cast<void**>(arg);
    void* frame = *slot;
    *slot = nullptr;  // ownership is ours now
    return frame;
  }
  return nullptr;
}

// TransformedFrameCallback: 4 OnTransformedFrame(unique_ptr).
void Deliver(void* cb, void* frame) {
  auto fn = Slot<void (*)(void*, void*)>(cb, 4);
  if (g_unique_ptr_abi.load() == 1) {
    fn(cb, frame);
  } else {
    void* slot = frame;
    fn(cb, &slot);
    if (slot) DeleteFrame(slot);
  }
}

/// Same virtual order as webrtc::FrameTransformerInterface. scoped_refptr
/// arguments are non-trivial, so they arrive as a pointer to the pointer.
class Transformer {
 public:
  Transformer(bool send, Media media, int opus_pt, int red_pt)
      : send_(send), media_(media), opus_pt_(opus_pt), red_pt_(red_pt) {}

  virtual void AddRefSelf() const { refs_.fetch_add(1); }
  virtual int ReleaseSelf() const {
    if (refs_.fetch_sub(1) == 1) {
      delete this;
      return 0;  // kDroppedLastRef
    }
    return 1;  // kOtherRefsRemained
  }
  virtual ~Transformer() {
    for (auto& [ssrc, cb] : sinks_) Release(cb);
    if (default_) Release(default_);
  }
  virtual void Transform(void* unique_frame) {
    void* frame = TakeFrame(unique_frame);
    if (!frame) return;  // undecidable ABI: drop rather than guess
    const uint32_t ssrc = GetSsrc(frame);
    if (enabled_.load()) Process(frame);
    void* cb = Callback(ssrc);
    if (!cb) return DeleteFrame(frame);
    Deliver(cb, frame);
    Release(cb);
  }
  virtual void RegisterTransformedFrameCallback(void** cb) { Set(&default_, cb ? *cb : nullptr); }
  virtual void RegisterTransformedFrameSinkCallback(void** cb, uint32_t ssrc) {
    std::lock_guard<std::mutex> l(mu_);
    void*& slot = sinks_[ssrc];
    if (slot) Release(slot);
    slot = cb ? *cb : nullptr;
    if (slot) AddRef(slot);
  }
  virtual void UnregisterTransformedFrameCallback() { Set(&default_, nullptr); }
  virtual void UnregisterTransformedFrameSinkCallback(uint32_t ssrc) {
    std::lock_guard<std::mutex> l(mu_);
    auto it = sinks_.find(ssrc);
    if (it == sinks_.end()) return;
    if (it->second) Release(it->second);
    sinks_.erase(it);
  }

  bool Age(int window_ms, double* median_ms, int* count) {
    std::vector<std::pair<int64_t, int64_t>> copy;
    {
      std::lock_guard<std::mutex> l(mu_);
      copy.assign(arrivals_.begin(), arrivals_.end());
    }
    return MedianAge(copy, NowUs() - int64_t{window_ms} * 1000, median_ms, count);
  }
  int64_t stamped() const { return stamped_.load(); }
  void Disable() { enabled_ = false; }

 private:
  void Set(void** slot, void* cb) {
    std::lock_guard<std::mutex> l(mu_);
    if (*slot) Release(*slot);
    *slot = cb;
    if (cb) AddRef(cb);
  }

  void* Callback(uint32_t ssrc) {
    std::lock_guard<std::mutex> l(mu_);
    auto it = sinks_.find(ssrc);
    void* cb = it != sinks_.end() ? it->second : default_;
    if (cb) AddRef(cb);
    return cb;
  }

  void Process(void* frame) {
    const View in = GetData(frame);
    if (!in.data || in.size == 0 || in.size > (64u << 20)) return;  // not a sane frame
    const int64_t now = NowUs();
    if (send_) {
      const auto trailer = BuildTrailer(static_cast<uint64_t>(now));
      std::vector<uint8_t> out;
      if (media_ == Media::kVideo) {
        out.assign(in.data, in.data + in.size);
        out.insert(out.end(), trailer.begin(), trailer.end());
      } else {
        const int pt = GetPayloadType(frame);
        const bool ok = pt == red_pt_ ? RedWithPadding(in.data, in.size, trailer, &out)
                        : pt == opus_pt_ ? OpusWithPadding(in.data, in.size, trailer, &out)
                                         : false;
        if (!ok) return;
      }
      SetData(frame, out);
      stamped_.fetch_add(1);
      return;
    }
    uint64_t stamp = 0;
    const size_t len = ParseTrailer(in.data, in.size, &stamp);
    if (!len) return;
    {
      std::lock_guard<std::mutex> l(mu_);
      arrivals_.emplace_back(now, now - static_cast<int64_t>(stamp));
      while (arrivals_.size() > 256) arrivals_.pop_front();
    }
    // Video: hand the decoder the frame as sent. Audio: padding is already
    // invisible to the decoder, so leave the packet alone.
    if (media_ == Media::kVideo) SetData(frame, std::vector<uint8_t>(in.data, in.data + in.size - len));
  }

  const bool send_;
  const Media media_;
  const int opus_pt_, red_pt_;
  mutable std::atomic<int> refs_{0};
  std::atomic<int64_t> stamped_{0};
  std::atomic<bool> enabled_{true};
  std::mutex mu_;
  void* default_ = nullptr;
  std::map<uint32_t, void*> sinks_;
  std::deque<std::pair<int64_t, int64_t>> arrivals_;  // (arrived at, age) µs
};

std::mutex g_mu;
std::map<std::string, Transformer*> g_registry;  // each holds one reference

void Install(void* native, int slot, Transformer* t) {
  // SetFrameTransformer(scoped_refptr<FrameTransformerInterface>): pass a
  // pointer to an owned reference; the callee copies or moves it out. Never
  // null — libwebrtc's delegates dereference the transformer unchecked.
  void* ref = t;
  t->AddRefSelf();
  Slot<void (*)(void*, void**)>(native, slot)(native, &ref);
  if (ref) static_cast<Transformer*>(ref)->ReleaseSelf();
}

bool Add(const std::string& id, void* native, int slot, Transformer* t) {
  if (!native) return false;
  t->AddRefSelf();  // the registry's reference
  {
    std::lock_guard<std::mutex> l(g_mu);
    auto it = g_registry.find(id);
    if (it != g_registry.end()) {
      it->second->Disable();
      it->second->ReleaseSelf();
    }
    g_registry[id] = t;
  }
  Install(native, slot, t);
  return true;
}

}  // namespace

bool StampSender(const std::string& id, void* native, Media media, int opus_pt, int red_pt) {
  // Audio needs the negotiated Opus type; before negotiation, try again later.
  if (media == Media::kAudio && opus_pt < 0) return false;
  return Add(id, native, kSenderSetFrameTransformer,
             new Transformer(true, media, opus_pt, red_pt));
}

bool ReadReceiver(const std::string& id, void* native, Media media) {
  return Add(id, native, kReceiverSetFrameTransformer, new Transformer(false, media, -1, -1));
}

void Forget(const std::string& id) {
  // libwebrtc keeps its reference until the sender/receiver goes away; the
  // transformer just turns into a pass-through.
  std::lock_guard<std::mutex> l(g_mu);
  auto it = g_registry.find(id);
  if (it == g_registry.end()) return;
  it->second->Disable();
  it->second->ReleaseSelf();
  g_registry.erase(it);
}

bool ReceiverAge(const std::string& id, int window_ms, double* median_ms, int* count) {
  Transformer* t;
  {
    std::lock_guard<std::mutex> l(g_mu);
    auto it = g_registry.find(id);
    if (it == g_registry.end()) return false;
    t = it->second;
    t->AddRefSelf();
  }
  const bool ok = t->Age(window_ms, median_ms, count);
  t->ReleaseSelf();
  return ok;
}

int64_t StampedCount(const std::string& id) {
  std::lock_guard<std::mutex> l(g_mu);
  auto it = g_registry.find(id);
  return it == g_registry.end() ? -1 : it->second->stamped();
}

}  // namespace nile_rs
