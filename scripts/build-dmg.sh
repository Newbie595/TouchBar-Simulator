#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${BUILD_ROOT:-$project_root/build}"
derived_data="$build_root/DerivedData"
app_path="$derived_data/Build/Products/Release/TouchBar Simulator.app"
service_path="$app_path/Contents/XPCServices/TouchBarSimulatorService.xpc"
dmg_path="$build_root/TouchBar-Simulator-universal.dmg"

# 即使已安装完整 Xcode，xcode-select 也可能仍指向独立的命令行工具。
# 先使用当前设置；若不可用则改用 /Applications/Xcode.app，
# 无需管理员密码即可构建这个项目。
if ! xcodebuild -version >/dev/null 2>&1 && \
   [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    echo '完整 Xcode 未安装、许可未接受，或尚未通过 xcode-select 选中。' >&2
    echo '请安装兼容当前 macOS 的 Xcode，将它放入 /Applications，并完成首次启动配置。' >&2
    exit 1
fi

mkdir -p "$build_root"

# 同时构建 Apple 芯片和 Intel 架构，让一个 DMG 可用于两类 Mac。
# 构建完成后使用临时签名，供个人测试。
xcodebuild \
    -project "$project_root/TouchBar Simulator.xcodeproj" \
    -scheme 'TouchBar Simulator' \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

test -d "$service_path"
test -f "$app_path/Contents/MacOS/TouchBar Simulator"
test -f "$service_path/Contents/MacOS/TouchBarSimulatorService"

for binary in "$app_path/Contents/MacOS/TouchBar Simulator" \
              "$service_path/Contents/MacOS/TouchBarSimulatorService"; do
    architectures="$(lipo -archs "$binary")"
    echo "$binary: $architectures"
    [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || {
        echo "缺少 arm64 或 x86_64 架构: $binary" >&2
        exit 1
    }
done

# 先签名内嵌的 XPC 服务，再签名主应用。临时签名仅供本机测试，
# 公开分发仍需 Developer ID 签名与 Apple 公证。
codesign --force --sign - --timestamp=none "$service_path"
codesign --force --sign - --timestamp=none \
    --entitlements "$project_root/TouchBar Simulator/TouchBar_Simulator.entitlements" \
    "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app_path" "$staging/TouchBar Simulator (Newbie595).app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -ov -format UDZO -volname 'TouchBar Simulator' \
    -srcfolder "$staging" "$dmg_path"
hdiutil verify "$dmg_path"
echo "DMG 已生成: $dmg_path"
