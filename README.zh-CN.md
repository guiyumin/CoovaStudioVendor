# CoovaStudioVendor

[English](README.md)

酷丸工具箱（Coova Studio）用到的第三方依赖，全部在这里从源码构建、锁定版本、发布成品。
App 仓库只下载这里发布的二进制，不依赖用户机器上的任何东西。

目前只有 ffmpeg，以后其他依赖也照此办理。

## ffmpeg

`ffmpeg/build.sh` 从上游源码构建静态链接的 `ffmpeg` 和 `ffprobe`（macOS，Apple Silicon）。

- 所有版本号、源码地址、SHA-256 写死在脚本顶部，升级只改那里。
- 第三方库全部静态链接，成品只依赖 macOS 自带的系统库和框架，脚本会用 `otool -L` 检查。
- `ffprobe` 单独构建：解码器和解封装器与 `ffmpeg` 相同，但不带编码器、写文件的封装器，也不链接只做编码的库
  （x264、x265、SVT-AV1、LAME），否则静态链接会把它们也打包进去。它只读文件，这样体积大约减半。
  自检会确认两者能解的编码完全一致。
- 最低系统版本 macOS 12。
- GPL 构建（含 x264、x265），不含任何 nonfree 组件（没有 fdk-aac）。

第一版包含：x264、x265（8-bit）、libvpx、dav1d、opus、libogg + libvorbis、lame；
`ffmpeg-9.0.1-2` 起加入 SVT-AV1（AV1 编码）；`ffmpeg-9.0.1-3` 起 x265 能编 8、10、12 bit
（按 x265 的 multilib 做法，同一个库编三遍再合成一个）。
硬件编解码走系统 VideoToolbox，AAC 用 ffmpeg 内置编码器。

### 本地构建

```sh
brew install cmake meson ninja pkgconf   # 只是构建工具，和运行时无关
ffmpeg/build.sh
```

产物在 `dist/ffmpeg/`：

- `ffmpeg-<版本>-macos-arm64.tar.gz`：里面是 `ffmpeg`、`ffprobe` 和许可证文件
- `SHA256SUMS`
- `BUILD-INFO.txt`：每个库的版本和 ffmpeg 的 configure 参数
- `sources/`：构建用到的全部源码包（GPL 要求随二进制一起提供）

中间文件在 `work/`，`work/` 和 `dist/` 都不进 git。

### CI 发布

GitHub Actions（`.github/workflows/ffmpeg.yml`）在 `macos-latest`（Apple Silicon）上跑同一个脚本。
打 `ffmpeg-*` 的 tag（比如 `ffmpeg-9.0.1`）会构建并把产物和源码包发到 Release；手动触发只构建不发布。

App 仓库的 `scripts/fetch-ffmpeg.sh` 指向这里的 Release 地址并锁定 SHA-256。

### 升级 ffmpeg 或某个库

1. 改 `ffmpeg/build.sh` 顶部的版本号和哈希。
2. 本地跑通，或者直接打 tag 让 CI 构建。
3. 在 app 仓库更新 `scripts/fetch-ffmpeg.sh` 里的地址和哈希，所有人重新跑一次脚本即可。
