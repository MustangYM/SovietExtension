//
//  RevokePatch.h
//  SovietExtension
//
//  Created by MustangYM on 2026/6/12.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
void YMLog(NSString *format, ...);
// 当前 /Applications/WeChat.app/Contents/Resources/wechat.dylib 的 ASLR slide。
// dyld 加载 wechat.dylib 后会赋值。
uintptr_t YMRuntimeAddress(uintptr_t staticVA);
uintptr_t getDylibSlide();

BOOL YMPatchARM64AbsoluteJump(uintptr_t address, uintptr_t targetAddress, const char *name);
// dyld 目标镜像加载后尝试安装；已安装或版本/ABI 不匹配时直接返回，不发送消息。
void YMInstallMessageMenuPatch(void);

NS_ASSUME_NONNULL_END
