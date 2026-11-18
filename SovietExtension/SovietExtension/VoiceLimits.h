#pragma once
// 长语音实验统一边界；实际音频时长与气泡显示时长独立。
enum {
    YMVoiceMaxDurationSeconds = 300,
    YMVoiceMaxDurationMS = YMVoiceMaxDurationSeconds * 1000,
    YMVoiceMaxEncodedBytes = 1024 * 1024,
    YMVoiceMaxTextLength = 3000,
    YMVoiceMaxResponseBytes = 32 * 1024 * 1024
};
