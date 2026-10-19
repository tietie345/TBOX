#!/bin/bash
# 创建固定自签名证书，解决 adhoc 签名导致 TCC 权限反复失效的问题
# 只需运行一次，永久有效

set -euo pipefail

CERT_NAME="TBOX Development"
CERT_DIR="$HOME/.tbox_cert"

echo "=== 创建 TBOX 固定签名证书 ==="

# 如果证书已存在，跳过
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "证书 '$CERT_NAME' 已存在，跳过创建。"
    # 即使证书已存在，也要重复设置一次 trustAsRoot；旧版本脚本曾使用
    # trustRoot，可能留下“可签名但不受信任”的证书状态。
    if [ -f "$CERT_DIR/cert.der" ]; then
        security add-trusted-cert -d -r trustAsRoot -k "$HOME/Library/Keychains/login.keychain-db" "$CERT_DIR/cert.der" 2>/dev/null || \
            security add-trusted-cert -d -r trustAsRoot -k "$HOME/Library/Keychains/login.keychain" "$CERT_DIR/cert.der" 2>/dev/null || true
    fi
    echo ""
    echo "可用证书:"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# 1. 生成自签名证书（必须包含三个扩展：CA:FALSE + digitalSignature + codeSigning）
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -subj "/CN=TBOX Development" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"

echo "证书生成成功"

# 2. 导出 DER 格式
openssl x509 -in cert.pem -out cert.der -outform DER

# 3. 导出 p12（OpenSSL 3.x 需要 -legacy）
openssl pkcs12 -export -inkey key.pem -in cert.pem \
    -out cert.p12 -passout pass:tbox -legacy 2>/dev/null || \
openssl pkcs12 -export -inkey key.pem -in cert.pem \
    -out cert.p12 -passout pass:tbox

# 4. 导入 Keychain
security import cert.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P tbox -A 2>/dev/null || \
security import cert.p12 -k "$HOME/Library/Keychains/login.keychain" -P tbox -A

# 5. 标记为信任。该证书是可用于代码签名的自签名叶证书（CA:FALSE），
# 因此应以 trustAsRoot 导入；trustRoot 会被 macOS 的链验证拒绝，导致
# codesign 报 CSSMERR_TP_NOT_TRUSTED。
security add-trusted-cert -d -r trustAsRoot -k "$HOME/Library/Keychains/login.keychain-db" cert.der 2>/dev/null || \
 security add-trusted-cert -d -r trustAsRoot -k "$HOME/Library/Keychains/login.keychain" cert.der 2>/dev/null || true

echo ""
echo "=== 证书已安装到钥匙串 ==="
echo "证书名称: $CERT_NAME"
echo ""
echo "下次运行 build_app.sh 将自动使用此证书签名。"
echo ""
echo "⚠️  重要：请手动执行以下操作修复权限："
echo "  1. 打开 系统设置 → 隐私与安全性 → 屏幕录制"
echo "  2. 找到 TBOX，选中后点击 - 号删除"
echo "  3. 打开 系统设置 → 隐私与安全性 → 辅助功能"
echo "  4. 同样删除 TBOX"
echo "  5. 重新运行 build_app.sh，启动后按快捷键触发权限弹窗并授权"
