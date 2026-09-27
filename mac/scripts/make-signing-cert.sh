#!/bin/zsh
# Crea (una sola vez) un certificado propio para firmar postPod siempre con la misma identidad.
# Sin esto cada compilación queda con una firma distinta y macOS vuelve a pedir la clave de la Mac
# para leer la contraseña guardada en el llavero.
set -euo pipefail
NAME="postPod Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "ya existe: $NAME"; exit 0; fi
TMP=$(mktemp -d)
cat > $TMP/cfg <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = aitism.space
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config $TMP/cfg -keyout $TMP/key.pem -out $TMP/cert.pem 2>/dev/null
PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -name "$NAME" -passout pass:$PASS -out $TMP/id.p12 2>/dev/null
security import $TMP/id.p12 -k ~/Library/Keychains/login.keychain-db -P $PASS -T /usr/bin/codesign >/dev/null
rm -rf $TMP
echo "OK: $NAME"
