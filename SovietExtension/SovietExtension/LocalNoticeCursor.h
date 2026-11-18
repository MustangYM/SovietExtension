#pragma once
#import <Foundation/Foundation.h>

// 沿用微信分页流程，以已加载消息的数据库排序边界替换查询起点。
// 加载时机、数量和结束判断仍由微信负责；边界仅用于本次同步调用。
BOOL YMInstallLocalNoticeCursorHooks(void);
