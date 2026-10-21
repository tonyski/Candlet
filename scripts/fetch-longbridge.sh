#!/bin/zsh
# 下载长桥 CLI（arm64，macOS 27 只支持 Apple 芯片），校验后连同许可证放进 Vendor/（不进 git）
# 编译时由 Xcode 复制到 Candlet.app/Contents/Helpers 并签名。升级 CLI：改下面的版本和校验值，重新运行
set -euo pipefail

cd "${0:A:h}/.."
VERSION=0.30.0
SHA256=3a2b3f1f7101aa992ae723cf55153116ea576a7915ce4b4ceb14c9aafbfc4ee7
BASE=https://github.com/longbridge/longbridge-terminal
OUT=Vendor
STAMP="$VERSION arm64"

if [[ -x $OUT/longbridge && $(cat $OUT/longbridge.version 2>/dev/null) == $STAMP ]]; then
  echo "长桥 CLI $VERSION 已就绪"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
echo "==> 下载长桥 CLI $VERSION"
curl -fsSL -o $WORK/cli.tar.gz $BASE/releases/download/v$VERSION/longbridge-terminal-darwin-arm64.tar.gz
print -r -- "$SHA256  $WORK/cli.tar.gz" | shasum -a 256 -c --quiet || { echo "校验失败"; exit 1; }
tar xzf $WORK/cli.tar.gz -C $WORK longbridge

mkdir -p $OUT
mv $WORK/longbridge $OUT/longbridge
chmod +x $OUT/longbridge
curl -fsSL -o $OUT/longbridge-LICENSE https://raw.githubusercontent.com/longbridge/longbridge-terminal/v$VERSION/LICENSE
print -r -- $STAMP > $OUT/longbridge.version
echo "==> 完成：$OUT/longbridge"
