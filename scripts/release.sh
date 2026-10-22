#!/bin/zsh
# 打包发布版：Developer ID 签名 → DMG → 公证 → 钉票，产物在 dist/Candlet-<版本>.dmg
# 需要先保存公证凭据：xcrun notarytool store-credentials candlet-notary --apple-id <邮箱> --team-id 5D7DFRZPJ7
set -euo pipefail

cd "${0:A:h}/.."
PROFILE=${NOTARY_PROFILE:-candlet-notary}
BUILD=build/release
VERSION=$(xcodebuild -project Candlet.xcodeproj -scheme Candlet -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
DMG=dist/Candlet-$VERSION.dmg
APP=$BUILD/Build/Products/Release/Candlet.app

scripts/fetch-longbridge.sh

echo "==> 编译 Candlet $VERSION"
rm -rf $BUILD
# build 默认不 strip，打开 DEPLOYMENT_POSTPROCESSING 去掉符号（主程序约小一半），dSYM 照常生成
xcodebuild -project Candlet.xcodeproj -scheme Candlet -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath $BUILD DEPLOYMENT_POSTPROCESSING=YES clean build -quiet 2>&1 | grep -v -e appintents -e IDERunDestination || true
[[ -d $APP ]] || { echo "编译失败"; exit 1; }
codesign --verify --deep --strict $APP
SIGNATURE=$(codesign -dv --verbose=2 $APP 2>&1)
[[ $SIGNATURE == *"Authority=Developer ID Application"* ]] || { echo "App 没有用 Developer ID 签名"; exit 1; }
codesign -d --entitlements - $APP 2>/dev/null | grep -q get-task-allow && { echo "App 带有 get-task-allow 权限，无法公证"; exit 1; }

echo "==> 制作 DMG"
STAGE=$(mktemp -d)
trap 'rm -rf $STAGE' EXIT
ditto $APP $STAGE/Candlet.app
ln -s /Applications $STAGE/Applications
mkdir -p dist
rm -f $DMG
# LZMA 压缩，比默认的 UDZO 小约 2 MB（主要是长桥 CLI）
hdiutil create -volname Candlet -srcfolder $STAGE -format ULMO -fs APFS $DMG -quiet
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
codesign --sign "$IDENTITY" --timestamp $DMG

echo "==> 提交公证（通常几分钟）"
RESULT=$(xcrun notarytool submit $DMG --keychain-profile $PROFILE --wait --output-format json)
STATUS=$(print -r -- $RESULT | plutil -extract status raw -o - -)
if [[ $STATUS != Accepted ]]; then
  echo "公证未通过：$STATUS"
  xcrun notarytool log $(print -r -- $RESULT | plutil -extract id raw -o - -) --keychain-profile $PROFILE
  exit 1
fi
xcrun stapler staple $DMG
spctl --assess --type open --context context:primary-signature -v $DMG

echo "==> 完成：$DMG"
shasum -a 256 $DMG
