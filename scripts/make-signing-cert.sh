#!/bin/sh
# 生成本地部署签名用自签证书,导入登录钥匙串(build.sh 的签名身份)。
# 同一套做法来自 NemoNotch(2026-10-20 实测):ad-hoc 每次构建换 cdhash,
# 「合并即部署」的重装在 TCC/Keychain 眼里都是陌生 app,授权反复重弹;
# 自签证书让重装保持同一身份。
# 使用场景:首次启用;证书丢失/过期/换开发机后重建。
# 同名身份已存在时拒绝 — 先删旧的再重建(删除后 TCC/Keychain 授权会按新
# 身份重新授予一次,这是身份切换的一次性成本,预期内)。
#
# Usage: sh scripts/make-signing-cert.sh
set -u

IDENTITY="NemoNoise Local Code Signing"
DAYS=3650   # 10 年:过期 = 锚定其上的全部授权集体孤儿化,宁长勿短
# security login-keychain 的输出带前导空格和引号,两者都剥掉
KEYCHAIN=$(security login-keychain | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# 用 codesign 本身探身份是否可用(真源判据):find-identity -p codesigning
# 对没有信任设置的自签证书不显示,拿它当存在性检查会漏判
# → 重复导入同名身份 → codesign 二义报错。
identity_usable() {
  p=$(mktemp) && printf 'probe' > "$p"
  codesign -f -s "$IDENTITY" "$p" >/dev/null 2>&1
  rc=$?
  rm -f "$p"
  return $rc
}

if identity_usable; then
  echo "✋ 身份 '$IDENTITY' 已可用 — 不重复生成。" >&2
  echo "   确要重建:先在钥匙串访问里删除该证书,再跑本脚本。" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM

# 自签 leaf:codeSigning EKU + digitalSignature。不需要加进系统信任设置 —
# codesign 用证书签名不要求证书被信任;信任链只在别人验证时被评估,而
# Gatekeeper 对分发包的验证本来就要求公证,自签过不了(与 ad-hoc 等价)。
cat > "$workdir/codesign.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_cs
prompt = no
[dn]
CN = NemoNoise Local Code Signing
O = NemoNoise
[v3_cs]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成密钥 + 自签证书(RSA 3072,${DAYS} 天)..."
openssl req -x509 -newkey rsa:3072 -nodes \
  -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
  -days "$DAYS" -config "$workdir/codesign.cnf"

# 「私钥 PEM + 证书 PEM 分开导入」:钥匙串按公钥自动配对成身份。
# 不打包 p12 —— Homebrew OpenSSL 4 产出的 p12 默认加密格式会让
# security import 报「MAC verification failed」,分开导入与版本无关。
echo "==> 导入私钥与证书到登录钥匙串(允许 /usr/bin/codesign 直接使用私钥)..."
security import "$workdir/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$workdir/cert.pem" -k "$KEYCHAIN"

echo "==> 验证(codesign 实签一个探针目标)..."
if identity_usable; then
  echo "✅ 身份已就绪: $IDENTITY(有效期 ${DAYS} 天,活在登录钥匙串)"
  echo ""
  echo "   备份建议(私钥丢了 = 全部授权重新授予):"
  echo "     security export -k '$KEYCHAIN' -t identities -p '$IDENTITY' -o ~/NemoNoise-signing-backup.p12"
  echo "   说明:find-identity -p codesigning 不显示本证书属预期(自签未设信任)。"
  echo "   下一步: ./build.sh 用它签名并部署到 /Applications;第一次替换"
  echo "   ad-hoc/旧签名版本后,TCC 授权会按新身份重新授予一次(一次性成本)。"
else
  echo "❌ codesign 解析不到身份 — 检查上方 security import 的报错" >&2
  exit 1
fi
