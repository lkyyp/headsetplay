# 蓝牙耳机续播

蓝牙耳机或车载音频连接后，自动打开所选音乐 App，并可选继续播放。

工程路径：`/var/minis/shared/headsetplay`

## 功能

- 注入 SpringBoard，监听蓝牙音频设备新连接
- 设置里可选手动打开的音乐 App
- 打开后通过 MediaRemote 发送播放指令
- 正在播放时默认不打断
- 键盘、手表等非音频蓝牙设备不会触发
- AirPods 左右耳短时间分别连接只会触发一次

## 设置

安装后打开 **设置 → 蓝牙耳机续播**：

1. 打开「启用插件」（默认关闭）
2. 选择要自动打开的音乐 App
3. 按需关闭「打开后继续播放」或「正在播放时不打断」

已连接的耳机不会立刻触发，需要重新连接一次。

## 可选 App

| 显示名 | 主包名 |
|---|---|
| 网易云音乐 | `com.netease.cloudmusic` |
| QQ音乐 | `com.tencent.QQMusic` |
| 酷我音乐 | `cn.kuwo.kwmusic` |
| 酷狗音乐 | `com.kugou.kugou1002` |
| Apple Music | `com.apple.Music` |
| 汽水音乐 | `com.luna.music` |
| 咪咕音乐 | `com.migu.migumusic` |
| Spotify | `com.spotify.client` |

未安装的 App 不会被打开。酷我、酷狗、QQ 音乐、汽水音乐会再尝试备用包名。

## 构建

本机需要 Theos。Minis 内只生成工程，不编译 deb。

```sh
sh build.sh rootless
```

也支持 `rootful`、`roothide` 或 `all`。GitHub Actions 默认打 Rootless 包。

安装后注销 SpringBoard。改设置后一般立即生效，不必再注销。
