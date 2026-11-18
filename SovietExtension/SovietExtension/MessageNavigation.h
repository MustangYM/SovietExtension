#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

void YMInstallMessageNavigationPatch(void);
void YMNavigateOriginalMessage(NSDictionary *record);
// 链接仅在当前电脑保存定位信息；没有可靠服务端消息 ID 时不生成。
NSString * _Nullable YMOriginalMessageLink(NSString *account, NSString *sourceSession,
    uint64_t serverID, uint32_t createSec, uint64_t sortSeq, uint32_t localID, BOOL forwarded);

NS_ASSUME_NONNULL_END
