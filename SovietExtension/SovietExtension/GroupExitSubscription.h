#pragma once
// WeChat arm64 Build 269079 ABI. RevokePatch verifies UUID/entry bytes and
// serializes subscription and cancellation on the native publishing runner.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <utility>

namespace YMGroupExitNativeABI {
using OnRoom = std::function<void(const std::string&)>;
static_assert(sizeof(OnRoom) == 32);
// The native UI passes empty second/third functions. Their argument types have
// not been proved, so represent only the verified empty storage, never invoke it.
struct EmptyFunction { std::uint64_t buffer[3]{}; void* target = nullptr; };
struct ObservableView {
    EmptyFunction lazySource;
    void* weakSubject = nullptr;
    void* weakControl = nullptr;
    std::uint64_t tail = 0; // UI writes 0; concrete source type not yet known.
};
struct SourceLocation {
    const char* function;
    const char* file;
    std::uint32_t line;
    std::uint32_t padding;
    const void* programCounter;
};
// Owning raw ABI return. Do not copy once live. releaseToken must run exactly
// once after cancel; native cancel alone leaves the first shared owner alive.
struct Token {
    std::uint64_t id = 0;
    void* cancelFlag = nullptr;
    void* cancelFlagControl = nullptr;
    void* cancelOwner = nullptr;
    void* cancelOwnerControl = nullptr;
};
static_assert(sizeof(EmptyFunction) == 32);
static_assert(offsetof(EmptyFunction, target) == 24);
static_assert(offsetof(ObservableView, weakSubject) == 32);
static_assert(offsetof(ObservableView, weakControl) == 40);
static_assert(sizeof(ObservableView) == 56);
static_assert(sizeof(SourceLocation) == 32);
static_assert(sizeof(Token) == 40);
static_assert(offsetof(Token, cancelOwner) == 24);
using Subscribe = Token (*)(ObservableView*, OnRoom*, EmptyFunction*, EmptyFunction*, const SourceLocation*);
using Cancel = void (*)(Token*);
using ReleaseToken = void (*)(Token*);
struct Calls { Subscribe subscribe; Cancel cancel; ReleaseToken releaseToken; };

// service and the subject must stay alive for this synchronous call. The view
// borrows weak fields; no retain/release is needed for the view itself. Native
// subscribe retains its own weak subject for the returned cancellation owner.
inline Token start(const Calls& f, const void* retainedService, OnRoom callback,
                   const SourceLocation& where) {
    void* subject = nullptr;
    std::memcpy(&subject, static_cast<const std::byte*>(retainedService) + 0x1b0, 8);
    if (!subject || !callback) return {};
    ObservableView view;
    std::memcpy(&view.weakSubject, static_cast<const std::byte*>(subject) + 8, 8);
    std::memcpy(&view.weakControl, static_cast<const std::byte*>(subject) + 16, 8);
    if (!view.weakSubject || !view.weakControl) return {};
    EmptyFunction second, third;
    return f.subscribe(&view, &callback, &second, &third, &where);
}
inline void cancelAndRelease(const Calls& f, Token& token) {
    if (!token.id && !token.cancelFlagControl && !token.cancelOwnerControl) return;
    f.cancel(&token);       // 0x5B78D0: explicit cancel and clear second shared ptr
    f.releaseToken(&token); // 0x17A070: shared-owner destructor, no automatic cancel
    token = {};
}
// Closure scheduling is a separate verified ABI. Prefer the application's
// native constructor at 0x30760; do not invent the query callback contract.
struct Closure;
struct ClosureHeader {
    std::uint32_t refs;
    std::uint32_t padding;
    void (*invoke)(Closure*);
    void (*destroy)(Closure*);
    void* query;
    std::uint64_t auxiliary;
};
static_assert(sizeof(ClosureHeader) == 40);
using InitClosure = void (*)(Closure*, void (*)(Closure*), void (*)(Closure*));
using ReleaseClosure = void (*)(Closure**); // 0x3084C; does not zero handle
// Integer x0 result; exact source-level bool/integer type remains unknown.
using PostRawRunner = std::uintptr_t (*)(void*, const SourceLocation*, Closure**, std::int64_t);
// 0x471392C moves *Closure** immediately and nulls the caller slot. It wraps a
// login check (4324E3C), so logged-out cancellation tasks can be DROPPED.
// 0x4713AC0 posts to the same runner without that login wrapper. It consumes
// *Closure** at +0x4713B0C..18. Precheck the mapped pointers at 93B02B0 and
// 93B02D8. Synchronize with app lifecycle; a raw read is not a shutdown barrier.
struct Closure {
    ClosureHeader header{};
    std::function<void()> body;
};
struct SchedulerCalls {
    InitClosure init;
    ReleaseClosure release;
    PostRawRunner post;
};
inline void invokeClosure(Closure* c) noexcept {
    try { c->body(); } catch (...) { /* do not unwind through private scheduler */ }
}
inline void destroyClosure(Closure* c) noexcept { delete c; }
// runner and environment are snapshot inputs read only after UUID/fingerprint
// checks. This does not by itself protect against concurrent process shutdown.
inline bool enqueue(const SchedulerCalls& f, void* runner, void* environment,
                    const SourceLocation& where, std::function<void()> body) {
    if (!runner || !environment || !body) return false;
    auto* c = new Closure;
    c->body = std::move(body);
    f.init(c, &invokeClosure, &destroyClosure);
    Closure* handle = c;
    const auto result = f.post(environment, &where, &handle, 0);
    // Native consumes and clears handle. This is also the native caller's
    // cleanup pattern, and covers a future failed call that left it nonempty.
    if (handle) f.release(&handle);
    // Low byte is the only portable success candidate until post return's
    // source-level type is proven; do not use it as an execution guarantee.
    return (result & 0xffu) != 0;
}
} // namespace
