# FL Camera · iPhone 试拍版 0.1

这是原生 SwiftUI/AVFoundation 源码工程，不是签名 IPA。仅使用系统框架，不需安装第三方依赖。Windows 上已验证工程引用和滤镜资源，尚未编译或真机试拍。

## 安装到自己的 iPhone

1. 在 Mac 上解压整个文件夹，用 Xcode 16 或更新版本打开 FL-Camera.xcodeproj。
2. 选择 FLCamera target → Signing & Capabilities，启用 Automatically manage signing，选择自己的 Team，并把示例 Bundle Identifier 改为自己的唯一标识。
3. 连接 iOS 16 或以上的 iPhone；按提示信任电脑、开启开发者模式。选中真机后按 ⌘R 编译安装。模拟器没有真实相机。
4. 第一次运行允许相机访问；按快门后允许添加照片。若拒绝，可在系统设置更改。首轮试拍请检查前后摄方向、镜像、滤镜浓度、预览流畅度与相册中的成片。
5. 若需分发 IPA，选择真机目标执行 Product → Archive，再在 Organizer 选择 Distribute App；分发方式取决于开发者账号及其签名权限。源码包不能直接在 iPhone 上安装。

## 操作与范围

竖屏「照片」模式：中央快门、前后摄切换、闪光灯、左下角系统照片选择器。点右上角滤镜按钮，切换原图、FL2、FL3、GR 正片或经典负片；可调滤镜强度与渲染曝光。拍照与选片均另存 JPEG，不覆盖原片。选片时确认使用当前参数后保存。

使用 sRGB 工作空间，读取 33³、RGBA Float32 LUT；这些是既有 DCP 的风格近似。曝光滑块为渲染亮度调整，不是传感器曝光补偿。预览限分辨率，保存使用照片输出；系统对视频和静态照片的处理不同，效果需以真机为准。

本版不含视频、人像、Live Photo、RAW/ProRAW 拍摄或桌面版完整修图面板。照片导入依赖当前 iOS 系统解码能力，未验证 RAW 兼容性。未制作上架素材或执行商店验证。
