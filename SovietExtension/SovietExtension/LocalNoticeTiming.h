#pragma once
#include <stdint.h>
#include <string.h>

// 关联提示沿用原消息时间；缺少排序值或加一会溢出时，回退到毫秒时间。
static inline uint64_t YMLocalNoticeSequenceAfter(uint64_t sequence, uint32_t seconds) {
    return sequence && sequence < UINT64_MAX ? sequence + 1 : uint64_t(seconds) * 1000;
}

// ARM 269079 MessageWrap 的时间与排序字段；调用方负责原生对象构造及版本校验。
static inline void YMSetLocalNoticeTiming(void *wrap, uint32_t seconds, uint64_t sequence) {
    memcpy(static_cast<uint8_t *>(wrap) + 0x114, &seconds, sizeof seconds);
    memcpy(static_cast<uint8_t *>(wrap) + 0x100, &sequence, sizeof sequence);
}
