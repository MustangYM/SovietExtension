// +1只负责将所选消息快照发回原会话；菜单和分组由MessageMenuPatch管理。
#import "MessageRepeatPatch.h"
#import "RevokePatch.h"
#import "ForwardToSelfPatch.h"

#if defined(__aarch64__)
std::function<void()> YMMessageRepeatAction(std::shared_ptr<YMMessageSnapshot> message, NSString *session) {
    return [message, session, used = false]() mutable {
        // 每次打开菜单持有独立快照；同一个 QAction 最多提交一次，防止重复触发。
        if (used) return;
        used = true;
        @autoreleasepool {
            BOOL submitted = YMForwardMessageDataToSession((uintptr_t)message.get(), session);
            YMLog(@"[MessageRepeat] clicked; submitted=%@ (delivery pending)", submitted ? @"YES" : @"NO");
        }
    };
}
#endif
