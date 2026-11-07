#!/bin/bash
# 本地构建、安装并启动 OneClick。直接运行 ./build.sh 即可。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_MODE="${BUILD_MODE:-local}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
BUILD_DIR="$ROOT_DIR/.build"
APP_PATH="$BUILD_DIR/DerivedData-$BUILD_MODE/Build/Products/$CONFIGURATION/OneClick.app"
TARGET_APP="$INSTALL_DIR/OneClick.app"
PREVIOUS_APP="$TARGET_APP"
APP_PROCESS_PATTERN='^(OneClick|RClick)$'
EXTENSION_PATTERN='/(OneClick|RClick)[.]app/Contents/PlugIns/FinderSyncExt[.]appex/Contents/MacOS/FinderSyncExt([[:space:]]|$)'
USER_ID="$(id -u)"
NEEDS_SUDO=false
WAS_RUNNING=false
APP_STOPPED=false
STAGING_DIR=""

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

as_installer() {
    if "$NEEDS_SUDO"; then sudo "$@"; else "$@"; fi
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$STAGING_DIR" ]]; then
        # 替换中途失败时恢复旧版本，不删除唯一的备份。
        if [[ -d "$STAGING_DIR/previous.app" && ! -e "$TARGET_APP" ]]; then
            if ! as_installer mv "$STAGING_DIR/previous.app" "$PREVIOUS_APP"; then
                printf '恢复失败，旧版本保存在：%s/previous.app\n' "$STAGING_DIR" >&2
                exit 1
            fi
        fi
        as_installer rm -rf "$STAGING_DIR" || true
    fi
    if [[ "$status" -ne 0 ]] && "$WAS_RUNNING" && "$APP_STOPPED"; then
        open "$PREVIOUS_APP" || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(uname -s)" == Darwin ]] || fail '此脚本只能在 macOS 上运行。'
[[ "$EUID" -ne 0 ]] || fail '请直接运行 ./build.sh，不要 sudo 整个脚本；安装需要时会自动请求权限。'
[[ "$CONFIGURATION" == Release || "$CONFIGURATION" == Debug ]] || fail 'CONFIGURATION 只能为 Release 或 Debug。'
[[ "$INSTALL_DIR" == /* ]] || fail 'INSTALL_DIR 必须是绝对路径。'
xcodebuild -version >/dev/null 2>&1 || fail '请先安装完整的 Xcode，并通过 xcode-select 选择它。'
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 27 ]] || fail '需要 Xcode 27 或更新版本及 macOS 27 SDK。'
SYSTEM_VERSION="$(sw_vers -productVersion)"
[[ "${SYSTEM_VERSION%%.*}" -ge 27 ]] || fail 'OneClick 的最低运行版本为 macOS 27 Golden Gate。'
[[ "$BUILD_MODE" == local || "$BUILD_MODE" == developer ]] || fail 'BUILD_MODE 只能为 local 或 developer。'
if [[ "$BUILD_MODE" == developer ]]; then
    [[ "$SIGNING_IDENTITY" != '-' ]] || fail '开发者模式不能使用 ad-hoc 签名。'
    SIGNING_IDENTITIES="$(security find-identity -v -p codesigning)"
    [[ "$SIGNING_IDENTITIES" =~ [[:xdigit:]]{40} ]] || fail '未找到可用的开发者签名证书。请先在 Xcode 中为两个 target 配置有权使用该 App Group 的 Team。'
fi
command -v python3 >/dev/null || fail '签名检查需要 python3（可由 Xcode 命令行工具提供）。'

log "构建 OneClick（${CONFIGURATION}，${BUILD_MODE}）"
mkdir -p "$BUILD_DIR"
BUILD_ARGS=(
    build
    -project "$ROOT_DIR/OneClick.xcodeproj"
    -scheme OneClick
    -configuration "$CONFIGURATION"
    -destination 'platform=macOS'
    -derivedDataPath "$BUILD_DIR/DerivedData-$BUILD_MODE"
)
if [[ "$BUILD_MODE" == local ]]; then
    BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RC_LOCAL_BUILD')
else
    BUILD_ARGS+=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES REGISTER_APP_GROUPS=YES)
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        BUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    fi
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        BUILD_ARGS+=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
    fi
fi
xcodebuild "${BUILD_ARGS[@]}" 2>&1 | tee "$BUILD_DIR/build.log"

[[ -x "$APP_PATH/Contents/MacOS/OneClick" ]] || fail "未找到构建产物：$APP_PATH"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/FinderSyncExt.appex"
[[ -d "$EXTENSION_PATH" ]] || fail '构建产物缺少 FinderSync 扩展。'

if [[ "$BUILD_MODE" == local ]]; then
    log '本地签名（无需开发者账号，保留沙盒）'
    python3 "$ROOT_DIR/scripts/local-entitlements.py" "$ROOT_DIR" "$BUILD_DIR/Signing"
    rm -f "$APP_PATH/Contents/embedded.provisionprofile" "$EXTENSION_PATH/Contents/embedded.provisionprofile"
    for helper in 7zz pigz; do
        codesign --force --options runtime --timestamp=none --sign - \
            --entitlements "$ROOT_DIR/Vendor/7zip/7zz.entitlements" "$APP_PATH/Contents/Helpers/$helper"
    done
    codesign --force --options runtime --timestamp=none --sign - \
        --entitlements "$BUILD_DIR/Signing/FinderSyncExt.entitlements" "$EXTENSION_PATH"
    codesign --force --options runtime --timestamp=none --sign - \
        --entitlements "$BUILD_DIR/Signing/OneClick.entitlements" "$APP_PATH"
else
    # 签名完整性通过不代表 App Group 已获授权，必须同时检查两份 profile。
    log '验证 App Group 授权'
python3 - "$ROOT_DIR/OneClick/OneClick.entitlements" "$APP_PATH" "$EXTENSION_PATH" <<'PY'
import datetime
import pathlib
import plistlib
import subprocess
import sys
import tempfile

def output(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

def require(condition, message):
    if not condition:
        raise ValueError(message)

try:
    expected_groups = set(plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())["com.apple.security.application-groups"])
    teams = set()
    for path in map(pathlib.Path, sys.argv[2:]):
        entitlements = plistlib.loads(output("codesign", "--display", "--entitlements", "-", "--xml", str(path)))
        team = entitlements.get("com.apple.developer.team-identifier")
        require(team, f"{path.name} 缺少开发者团队签名，不能使用 ad-hoc 签名。")
        teams.add(team)
        require(expected_groups <= set(entitlements.get("com.apple.security.application-groups", [])), f"{path.name} 缺少所需的 App Group entitlement。")
        profile_path = path / "Contents/embedded.provisionprofile"
        require(profile_path.is_file(), f"{path.name} 缺少 App Group provisioning profile。")
        profile = plistlib.loads(output("security", "cms", "-D", "-i", str(profile_path)))
        allowed = profile.get("Entitlements", {})
        require(team in profile.get("TeamIdentifier", []), f"{path.name} 的 profile 与签名团队不一致。")
        require(expected_groups <= set(allowed.get("com.apple.security.application-groups", [])), f"{path.name} 的 profile 未授权所需的 App Group。")
        identifier = entitlements.get("com.apple.application-identifier")
        bundle_id = plistlib.loads((path / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        require(identifier and identifier.endswith("." + bundle_id) and identifier == allowed.get("com.apple.application-identifier"), f"{path.name} 的 App ID 与 profile 不一致。")
        require(profile.get("ExpirationDate", datetime.datetime.min) > datetime.datetime.utcnow(), f"{path.name} 的 profile 已过期。")
        with tempfile.TemporaryDirectory() as temp:
            prefix = str(pathlib.Path(temp) / "certificate")
            output("codesign", "--display", "--extract-certificates", prefix, str(path))
            certificate = pathlib.Path(prefix + "0").read_bytes()
        require(certificate in profile.get("DeveloperCertificates", []), f"{path.name} 的签名证书不在 profile 中。")
        print(f"已验证：{path.name}（Team {team}）")
    require(len(teams) == 1, "主应用和 Finder 扩展必须由同一团队签名。")
except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
    sys.exit(f"签名检查失败，已取消安装：{error}")
PY
fi
codesign --verify --deep --strict "$APP_PATH"
python3 "$ROOT_DIR/scripts/verify-runtime-entitlements.py" "$APP_PATH"

# 先完整复制到安装目录下的临时目录，构建或复制失败不会影响旧应用。
if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
    NEEDS_SUDO=true
    log '安装需要管理员权限'
    sudo -v
fi
as_installer mkdir -p "$INSTALL_DIR"
STAGING_DIR="$(as_installer mktemp -d "$INSTALL_DIR/.OneClick-install.XXXXXX")"
as_installer ditto "$APP_PATH" "$STAGING_DIR/OneClick.app"

# 旧版应用保留相同 bundle ID；首次安装更名版本时替换旧路径。
if [[ ! -e "$TARGET_APP" && -d "$INSTALL_DIR/RClick.app" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DIR/RClick.app/Contents/Info.plist" 2>/dev/null)" == cn.wflixu.RClick ]]; then
    PREVIOUS_APP="$INSTALL_DIR/RClick.app"
fi

if pgrep -u "$USER_ID" -x "$APP_PROCESS_PATTERN" >/dev/null; then
    WAS_RUNNING=true
    log '退出正在运行的 OneClick'
    osascript <<'APPLESCRIPT' || true
with timeout of 10 seconds
    if application id "cn.wflixu.RClick" is running then
        tell application id "cn.wflixu.RClick" to quit
    end if
end timeout
APPLESCRIPT
    for ((i = 0; i < 10; i++)); do
        pgrep -u "$USER_ID" -x "$APP_PROCESS_PATTERN" >/dev/null || break
        sleep 1
    done
    if pgrep -u "$USER_ID" -x "$APP_PROCESS_PATTERN" >/dev/null; then
        pkill -TERM -u "$USER_ID" -x "$APP_PROCESS_PATTERN" || true
        for ((i = 0; i < 5; i++)); do
            pgrep -u "$USER_ID" -x "$APP_PROCESS_PATTERN" >/dev/null || break
            sleep 1
        done
    fi
    if pgrep -u "$USER_ID" -x "$APP_PROCESS_PATTERN" >/dev/null; then
        fail 'OneClick 未能退出，已取消更新。'
    fi
    APP_STOPPED=true
fi

# Finder 扩展是独立进程，也需要结束才能加载新版；匹配新旧应用内的扩展。
if pgrep -u "$USER_ID" -f "$EXTENSION_PATTERN" >/dev/null; then
    log '停止旧版 Finder 扩展'
    pkill -TERM -u "$USER_ID" -f "$EXTENSION_PATTERN" || true
    for ((i = 0; i < 5; i++)); do
        pgrep -u "$USER_ID" -f "$EXTENSION_PATTERN" >/dev/null || break
        sleep 1
    done
    if pgrep -u "$USER_ID" -f "$EXTENSION_PATTERN" >/dev/null; then
        fail 'Finder 扩展未能退出，已取消更新。'
    fi
fi

log "安装到 $TARGET_APP"
if [[ -e "$PREVIOUS_APP" || -L "$PREVIOUS_APP" ]]; then
    as_installer mv "$PREVIOUS_APP" "$STAGING_DIR/previous.app"
fi
as_installer mv "$STAGING_DIR/OneClick.app" "$TARGET_APP"

# 注册新路径，保留用户在系统设置中选择的扩展开关状态。
if ! pluginkit -a "$TARGET_APP/Contents/PlugIns/FinderSyncExt.appex"; then
    printf '提示：Finder 扩展注册失败，可在系统设置中检查扩展状态。\n' >&2
fi
log '启动 OneClick'
open "$TARGET_APP"
log '完成'
