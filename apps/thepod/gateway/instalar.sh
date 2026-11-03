#!/usr/bin/env bash
# Instala el gateway de thePod dentro del contenedor (una sola vez, con sudo).
#
#   cd ~/thepod && sudo bash gateway/instalar.sh
#
# Qué hace:
#   1. Instala nginx (si no está).
#   2. Mueve thePod (gunicorn) del puerto 5003 al 5005.
#   3. Pone nginx a escuchar en 5003 (el puerto que el host manda a thepod.castmedia.space)
#      con gateway/thepod-gateway.conf: / → thePod, /pre /prod /ama /post → cada app.
#   4. Deja a admin recargar nginx y reiniciar los servicios sin contraseña (solo eso),
#      para que los despliegues sigan sin sudo.
# No toca el host ni los subdominios. Se puede volver atrás con: sudo bash gateway/instalar.sh --deshacer
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
CONF_SRC="$AQUI/thepod-gateway.conf"
CONF_DST="/etc/nginx/sites-available/thepod-gateway.conf"
UNIT="/etc/systemd/system/thepod.service"
USUARIO="${SUDO_USER:-admin}"

if [[ "${1:-}" == "--deshacer" ]]; then
  echo "· Deshaciendo: thePod vuelve a 5003 y nginx se apaga"
  systemctl disable --now nginx || true
  sed -i 's/--bind 0.0.0.0:5005/--bind 0.0.0.0:5003/' "$UNIT"
  systemctl daemon-reload && systemctl restart thepod
  echo "Listo."; exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Corre con sudo: sudo bash gateway/instalar.sh"; exit 1; }
[[ -f "$CONF_SRC" ]] || { echo "No encuentro $CONF_SRC"; exit 1; }

echo "· nginx"
if ! command -v nginx >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
fi
rm -f /etc/nginx/sites-enabled/default

echo "· thePod pasa a 5005"
if grep -q -- '--bind 0.0.0.0:5003' "$UNIT"; then
  sed -i 's/--bind 0.0.0.0:5003/--bind 0.0.0.0:5005/' "$UNIT"
fi
systemctl daemon-reload
systemctl restart thepod
sleep 2
curl -fsS -o /dev/null http://127.0.0.1:5005/ && echo "  thePod responde en 5005"

echo "· gateway en 5003"
install -m 644 "$CONF_SRC" "$CONF_DST"
ln -sf "$CONF_DST" /etc/nginx/sites-enabled/thepod-gateway.conf
# admin puede editar la config y recargar sin sudo
chown "$USUARIO" "$CONF_DST"
nginx -t
systemctl enable --now nginx
systemctl reload nginx
sleep 1
for u in / /pre/ /prod/ /ama/ /post/; do
  printf "  %-7s %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:5003$u")"
done

echo "· permisos para desplegar sin sudo"
cat > /etc/sudoers.d/thepod-gateway <<EOF
$USUARIO ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /bin/systemctl reload nginx, /bin/systemctl restart nginx, /bin/systemctl restart thepod, /bin/systemctl restart prepod, /bin/systemctl restart prodpod, /bin/systemctl restart amapod, /bin/systemctl restart postpod
EOF
chmod 440 /etc/sudoers.d/thepod-gateway
visudo -cf /etc/sudoers.d/thepod-gateway

echo
echo "Listo. thepod.castmedia.space/pre, /prod, /ama y /post ya responden."
