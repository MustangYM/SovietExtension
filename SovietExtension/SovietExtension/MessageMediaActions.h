#pragma once
#import "MessageMenuPatch.h"

#if defined(__aarch64__)
// 完整资源查询、Finder定位、表情下载/解码/另存为，以及各自ABI校验。
class YMMessageMediaActions {
public:
    // 由公共菜单在版本/UUID门控通过后初始化，早于任何动作创建。
    static void validateABI();
    // 主线程创建/触发；空回调表示不显示该项。回调持有快照，创建时不下载或导出。
    // Finder只接受已存在的完整缓存；点击时复检同一路径，缓存可能仍是微信私有格式。
    static std::function<void()> revealAction(std::shared_ptr<YMMessageSnapshot> message);
    // 仅独立媒体表情：点击后才按需下载、解码并打开保存面板。
    static std::function<void()> saveAction(std::shared_ptr<YMMessageSnapshot> message);
};
#endif
