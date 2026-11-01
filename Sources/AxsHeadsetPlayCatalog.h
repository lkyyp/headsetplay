#pragma once

#import <Foundation/Foundation.h>
#import <string.h>

typedef struct {
    const char *title;
    const char *bundleID;
    const char *const *alternates;
} AxsHeadsetPlayCatalogEntry;

static const char * const kAxsHeadsetPlayQQMusicAlts[] = {
    "com.tencent.QQMusicHD",
    NULL
};

static const char * const kAxsHeadsetPlayKuwoAlts[] = {
    "cn.kuwo.player",
    "com.kuwo.kwmusic",
    NULL
};

static const char * const kAxsHeadsetPlayKugouAlts[] = {
    "com.kugou.kugou1002.HD",
    NULL
};

static const char * const kAxsHeadsetPlayQishuiAlts[] = {
    "com.bytedance.qishui",
    NULL
};

static const AxsHeadsetPlayCatalogEntry kAxsHeadsetPlayCatalog[] = {
    { "网易云音乐", "com.netease.cloudmusic", NULL },
    { "QQ音乐", "com.tencent.QQMusic", kAxsHeadsetPlayQQMusicAlts },
    { "酷我音乐", "cn.kuwo.kwmusic", kAxsHeadsetPlayKuwoAlts },
    { "酷狗音乐", "com.kugou.kugou1002", kAxsHeadsetPlayKugouAlts },
    { "Apple Music", "com.apple.Music", NULL },
    { "汽水音乐", "com.luna.music", kAxsHeadsetPlayQishuiAlts },
    { "咪咕音乐", "com.migu.migumusic", NULL },
    { "Spotify", "com.spotify.client", NULL },
};

static const NSUInteger kAxsHeadsetPlayCatalogCount =
    sizeof(kAxsHeadsetPlayCatalog) / sizeof(kAxsHeadsetPlayCatalog[0]);

static inline NSString *axs_headsetplay_catalogTitleForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) {
        return @"未选择";
    }
    const char *needle = bundleID.UTF8String;
    for (NSUInteger index = 0; index < kAxsHeadsetPlayCatalogCount; index++) {
        const AxsHeadsetPlayCatalogEntry *entry = &kAxsHeadsetPlayCatalog[index];
        if (strcmp(entry->bundleID, needle) == 0) {
            return @(entry->title);
        }
        if (!entry->alternates) {
            continue;
        }
        for (const char *const *cursor = entry->alternates; *cursor; cursor++) {
            if (strcmp(*cursor, needle) == 0) {
                return @(entry->title);
            }
        }
    }
    return bundleID;
}

static inline NSArray<NSString *> *axs_headsetplay_catalogAlternateBundleIDs(NSString *bundleID) {
    if (bundleID.length == 0) {
        return @[];
    }
    const char *needle = bundleID.UTF8String;
    for (NSUInteger index = 0; index < kAxsHeadsetPlayCatalogCount; index++) {
        const AxsHeadsetPlayCatalogEntry *entry = &kAxsHeadsetPlayCatalog[index];
        if (strcmp(entry->bundleID, needle) != 0 || !entry->alternates) {
            continue;
        }
        NSMutableArray<NSString *> *items = [NSMutableArray array];
        for (const char *const *cursor = entry->alternates; *cursor; cursor++) {
            [items addObject:@(*cursor)];
        }
        return items;
    }
    return @[];
}
