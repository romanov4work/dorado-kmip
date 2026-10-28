#!/bin/bash
set -euo pipefail

echo "=== Установка Eviden KMS (Cosmian KMS) для Huawei Dorado ==="
echo ""

# Поддержка запуска как от root, так и от обычного пользователя с sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Проверка ОС
if [ ! -f /etc/os-release ]; then
    echo "❌ Не могу определить ОС (/etc/os-release не найден)"
    exit 1
fi

. /etc/os-release
if [[ ! "${ID:-}" =~ ^(ubuntu|debian|rocky|almalinux|centos|rhel)$ ]]; then
    echo "⚠️  ОС ${ID:-unknown} не входит в список стандартных (Ubuntu/Debian/Rocky/CentOS/RHEL), пробуем продолжить..."
fi

echo "✅ ОС: ${PRETTY_NAME:-Linux}"

# Определение IP-адреса сервера
DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
if [ -z "$DEFAULT_IP" ]; then
    DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
fi
SERVER_IP="${1:-$DEFAULT_IP}"

echo "🌐 Сервер будет настроен на IP: $SERVER_IP"
echo "   (Чтобы задать другой IP вручную: bash install.sh <НУЖНЫЙ_IP>)"

# Установка базовых пакетов и Python
echo ""
echo "🐍 Проверка системных пакетов и Python..."
if [[ "${ID:-}" =~ ^(rocky|almalinux|centos|rhel)$ ]]; then
    $SUDO yum install -y yum-utils curl openssl python3 python3-pip
else
    $SUDO apt-get update -qq
    $SUDO apt-get install -y ca-certificates curl openssl python3 python3-pip python3-venv
fi

# Установка Docker (адаптировано для работы в РФ без VPN)
echo ""
echo "📦 Проверка Docker..."
if ! command -v docker &> /dev/null; then
    echo "Установка Docker..."
    if [[ "${ID:-}" =~ ^(rocky|almalinux|centos|rhel)$ ]]; then
        # Используем зеркало Яндекса, так как download.docker.com блокирует запросы из РФ
        $SUDO yum-config-manager --add-repo https://mirror.yandex.ru/mirrors/docker-ce/linux/centos/docker-ce.repo || \
        $SUDO yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $SUDO sed -i 's|https://download.docker.com|https://mirror.yandex.ru/mirrors/docker-ce|g' /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
        $SUDO yum install -y docker-ce docker-ce-cli containerd.io
    else
        # На Ubuntu/Debian ставим docker.io из штатных репозиториев дистрибутива (не блокируется в РФ)
        $SUDO apt-get install -y docker.io
    fi
    $SUDO systemctl enable --now docker
    if [ "$EUID" -ne 0 ]; then
        $SUDO usermod -aG docker "$USER" || true
    fi
    echo "✅ Docker установлен"
else
    $SUDO systemctl start docker || true
    echo "✅ Docker уже установлен"
fi

# Удаление старого контейнера при перезапуске скрипта
$SUDO docker rm -f kms-server 2>/dev/null || true
sleep 1

# Проверка свободных портов
echo ""
echo "🔍 Проверка портов 5696 и 9998..."
for port in 5696 9998; do
    if command -v ss &>/dev/null && ss -tln | grep -q ":$port "; then
        echo "❌ Порт $port уже занят другим процессом:"
        $SUDO ss -tlnp | grep ":$port " || true
        exit 1
    fi
done
echo "✅ Порты 5696 и 9998 свободны"

# Открытие порта 5696 в файрволе (если активен)
if command -v ufw &>/dev/null && $SUDO ufw status | grep -q "Status: active"; then
    $SUDO ufw allow 5696/tcp >/dev/null 2>&1 || true
    echo "✅ Порт 5696/tcp открыт в UFW"
elif command -v firewall-cmd &>/dev/null && $SUDO systemctl is-active --quiet firewalld; then
    $SUDO firewall-cmd --add-port=5696/tcp --permanent >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    echo "✅ Порт 5696/tcp открыт в firewalld"
fi

# Генерация сертификатов
echo ""
echo "🔐 Генерация сертификатов KMIP (RSA 2048, X.509v3)..."
CERT_DIR="$HOME/kmip-certs"
mkdir -p "$CERT_DIR"
chmod 755 "$CERT_DIR"
cd "$CERT_DIR"

# 1. CA сертификат (срок 10 лет)
cat > ca.cnf << EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no

[req_dn]
C = RU
O = KMS-Server
CN = KMIP-CA

[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -config ca.cnf 2>/dev/null
echo "  ✅ CA сертификат создан (ca.crt)"

# 2. Серверный сертификат с SAN (IP + DNS)
cat > server.cnf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = RU
O = KMS-Server
CN = $SERVER_IP

[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = kms-server
IP.1 = 127.0.0.1
IP.2 = $SERVER_IP
EOF

openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -out server.csr -config server.cnf 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -days 3650 -sha256 \
    -extensions v3_req -extfile server.cnf 2>/dev/null
echo "  ✅ Серверный сертификат создан для IP: $SERVER_IP (server.crt)"

# 3. Клиентский сертификат для Huawei Dorado
cat > client.cnf << EOF
[req]
distinguished_name = req_dn
req_extensions = v3_client
prompt = no

[req_dn]
C = RU
O = Dorado-Client
CN = dorado-client

[v3_client]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = DNS:dorado-client
EOF

openssl genrsa -out client.key 2048 2>/dev/null
# Конвертация в классический RSA формат (PKCS#1: BEGIN RSA PRIVATE KEY) с поддержкой OpenSSL 3.x и 1.1.x
openssl rsa -in client.key -traditional -out client_rsa.key 2>/dev/null || \
openssl rsa -in client.key -out client_rsa.key 2>/dev/null || \
cp client.key client_rsa.key

openssl req -new -key client.key -out client.csr -config client.cnf 2>/dev/null
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out client.crt -days 3650 -sha256 \
    -extensions v3_client -extfile client.cnf 2>/dev/null
echo "  ✅ Клиентский сертификат создан (client.crt, client.key, client_rsa.key)"

rm -f *.csr *.cnf *.srl
chmod 644 "$CERT_DIR"/*.crt "$CERT_DIR"/*.key
echo "✅ Сертификаты сохранены в: $CERT_DIR"

# Установка Python-библиотек в виртуальное окружение (venv)
echo ""
echo "🐍 Настройка Python-окружения (pykmip, cryptography)..."
python3 -m venv "$CERT_DIR/venv"
"$CERT_DIR/venv/bin/pip" install --quiet --upgrade pip
"$CERT_DIR/venv/bin/pip" install --quiet pykmip cryptography
echo "✅ Python-окружение настроено"

# Создание тестового скрипта с патчем совместимости под Python 3.10-3.12+
cat > "$CERT_DIR/test.py" << EOFTEST
#!/usr/bin/env python3
"""
KMIP Native Protocol Test для Eviden KMS
Проверяет подключение к KMS через native KMIP binary protocol с mTLS
"""
import os
import ssl

# Патч совместимости для Python 3.12+, где удален ssl.wrap_socket, используемый внутри PyKMIP
if not hasattr(ssl, 'wrap_socket'):
    def _wrap_socket(sock, keyfile=None, certfile=None, server_side=False,
                     cert_reqs=ssl.CERT_NONE, ssl_version=ssl.PROTOCOL_TLS,
                     ca_certs=None, do_handshake_on_connect=True,
                     suppress_ragged_eofs=True, ciphers=None):
        ctx = ssl.SSLContext(ssl_version)
        ctx.verify_mode = cert_reqs
        if ca_certs:
            ctx.load_verify_locations(ca_certs)
        if certfile:
            ctx.load_cert_chain(certfile=certfile, keyfile=keyfile)
        if ciphers:
            ctx.set_ciphers(ciphers)
        return ctx.wrap_socket(
            sock,
            server_side=server_side,
            do_handshake_on_connect=do_handshake_on_connect,
            suppress_ragged_eofs=suppress_ragged_eofs
        )
    ssl.wrap_socket = _wrap_socket

from kmip.pie import client
from kmip import enums

CERT_DIR = os.path.dirname(os.path.abspath(__file__))
KMS_IP = os.environ.get('KMS_IP', '$SERVER_IP')

print("🔐 KMIP Native Protocol Test")
print(f"📂 Certificates: {CERT_DIR}")
print(f"🌐 KMS Server:   {KMS_IP}:5696")
print()

c = client.ProxyKmipClient(
    hostname=KMS_IP,
    port=5696,
    cert=f'{CERT_DIR}/client.crt',
    key=f'{CERT_DIR}/client.key',
    ca=f'{CERT_DIR}/ca.crt',
    ssl_version='PROTOCOL_TLSv1_2',
    config_file=None
)

try:
    print("🔌 Connecting to KMS...")
    c.open()
    print("✅ Connected successfully!")

    print("\n🔑 Creating test AES-256 key...")
    key_id = c.create(
        enums.CryptographicAlgorithm.AES,
        256,
        cryptographic_usage_mask=[
            enums.CryptographicUsageMask.ENCRYPT,
            enums.CryptographicUsageMask.DECRYPT
        ]
    )
    print(f"✅ Key created: {key_id}")

    print("\n📥 Getting key back...")
    key = c.get(key_id)
    print(f"✅ Key retrieved: {len(key.value)} bytes")

    print("\n🗑️  Destroying test key...")
    c.destroy(key_id)
    print("✅ Key destroyed")

    print("\n🎉 ALL TESTS PASSED!")
    print("✅ Native KMIP protocol работает отлично!")
    print("✅ Можно подключать Huawei Dorado!")

except Exception as e:
    print(f"\n❌ ERROR: {e}")
    import traceback
    traceback.print_exc()
    exit(1)
finally:
    try:
        c.close()
    except Exception:
        pass
EOFTEST

chmod +x "$CERT_DIR/test.py"
echo "  ✅ Тестовый скрипт готов: $CERT_DIR/test.py"

# Конфигурация KMS и директория данных
echo ""
echo "⚙️  Создание конфигурации KMS..."
KMS_DIR="$HOME/kms-config"
DATA_DIR="$HOME/kms-data"
mkdir -p "$KMS_DIR" "$DATA_DIR"
chmod 755 "$KMS_DIR"
chmod 777 "$DATA_DIR"

cat > "$KMS_DIR/kms.toml" << 'EOF'
# Eviden KMS Configuration for Native KMIP Protocol with Huawei Dorado

[tls]
tls_cert_file = "/certs/server.crt"
tls_key_file = "/certs/server.key"
clients_ca_cert_file = "/certs/ca.crt"

[socket_server]
socket_server_start = true
socket_server_hostname = "0.0.0.0"
socket_server_port = 5696

[http]
port = 9998
hostname = "0.0.0.0"

[db]
database_type = "sqlite"
sqlite_path = "/data"

[logging]
rust_log = "info,cosmian_kms_server=info"
EOF

chmod 644 "$KMS_DIR/kms.toml"
echo "✅ Конфигурация создана"

# Запуск KMS
echo ""
echo "🚀 Запуск Eviden KMS в Docker..."
$SUDO docker pull ghcr.io/cosmian/kms:5.28.0

$SUDO docker run -d \
    --name kms-server \
    --restart unless-stopped \
    -p 5696:5696 \
    -p 9998:9998 \
    -v "$CERT_DIR":/certs:ro,z \
    -v "$KMS_DIR":/config:ro,z \
    -v "$DATA_DIR":/data:z \
    ghcr.io/cosmian/kms:5.28.0 \
    --config /config/kms.toml

echo "⏳ Ожидание готовности TLS-сокета KMS на порту 5696 (до 30 секунд)..."

READY=0
for i in {1..30}; do
    if openssl s_client -connect 127.0.0.1:5696 \
        -cert "$CERT_DIR/client.crt" \
        -key "$CERT_DIR/client.key" \
        -CAfile "$CERT_DIR/ca.crt" </dev/null >/dev/null 2>&1; then
        READY=1
        echo ""
        echo "✅ KMS запущен и принимает TLS-соединения на порту 5696"
        break
    fi
    sleep 1
    echo -n "."
done

if [ "$READY" -ne 1 ]; then
    echo ""
    echo "❌ KMS не ответил по TLS на порту 5696 за 30 секунд. Логи контейнера:"
    $SUDO docker logs --tail 30 kms-server
    exit 1
fi

echo ""
echo "🧪 Автоматическая проверка KMIP-операций (создание/чтение/удаление ключа)..."
KMS_IP="127.0.0.1" "$CERT_DIR/venv/bin/python" "$CERT_DIR/test.py"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║       УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО         ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "📍 Параметры KMS сервера для Huawei Dorado:"
echo "   Server Type:  General KMIP"
echo "   Server IP:    $SERVER_IP"
echo "   Port:         5696"
echo "   Время на сервере (сверьте с Dorado): $(date)"
echo ""
echo "🔐 Файлы сертификатов для загрузки в Dorado (папка $CERT_DIR):"
echo "   Certificate File:     $CERT_DIR/client.crt"
echo "   CA Certificate File:  $CERT_DIR/ca.crt"
echo "   Private Key File:     $CERT_DIR/client.key (или client_rsa.key)"
echo ""