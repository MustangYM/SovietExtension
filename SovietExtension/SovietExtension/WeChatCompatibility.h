#import <Foundation/Foundation.h>

struct mach_header;
// 仅在 dyld 确认目标 Resources/wechat.dylib 已加载后调用；空指针不占用首次校验。
void YMInitializeWeChatCompatibility(const struct mach_header *image);
// 仅表示镜像身份；每个功能仍须分别核对本版本的布局、入口与 trampoline。
FOUNDATION_EXPORT BOOL YMMatchesWeChat270353Dylib(void);
