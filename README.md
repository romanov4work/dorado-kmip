# KMIP сервер (Eviden KMS) для Huawei Dorado

Готовый автоустановщик бесплатного сервера управления ключами **Eviden KMS** (Cosmian KMS, лицензия Apache 2.0) для работы с шифрованными дисками (SED) на СХД **Huawei OceanStor Dorado** через профиль **General KMIP**.
Почему автоустановщик, а не готовая виртуалка (.ova)
Для работы KMIP по TLS в сертификат сервера жестко вшивается реальный IP-адрес машины в сети заказчика (поле Subject Alternative Name). Если собрать виртуалку заранее, в сертификате будет чужой IP, и Dorado отвергнет соединение при проверке сертификата.
Скрипт на чистой Linux-виртуалке заказчика сам определяет IP и выпускает сертификаты под него. Это быстрее и надежнее, чем импорт чужого .ova в VMware ESXi, Proxmox, Hyper-V или российские гипервизоры.


## 1. Быстрый старт (установка за 2 минуты)
### Требования к серверу / виртуальной машине
- **ОС:** Ubuntu 22.04 / 24.04, Debian 11 / 12, Rocky Linux 8 / 9, AlmaLinux, CentOS, RHEL
- **Ресурсы:** 2 vCPU, 2–4 GB RAM, 20 GB Disk
- **Сеть:** сетевая доступность между KMS-сервером и управляющим портом Huawei Dorado по порту `5696/tcp`, доступ в интернет на время установки
### Запуск установки
1. Скопируйте `install.sh` на сервер:
curl -fsSL https://raw.githubusercontent.com/romanov4work/dorado-kmip/refs/heads/main/install.sh -o install.sh || wget -qO install.sh https://raw.githubusercontent.com/romanov4work/dorado-kmip/refs/heads/main/install.sh
2. Выполните:
```bash
bash install.sh
```
Скрипт автоматически определит основной IP-адрес сервера и пропишет его в сертификаты.
Если на сервере несколько сетевых интерфейсов и нужно привязать сертификат к конкретному IP-адресу, укажите его параметром:
```bash
bash install.sh 192.168.1.100
```


### Что скрипт делает автоматически
1. Устанавливает Docker и необходимые системные утилиты (если их еще нет)
2. Открывает порт 5696/tcp в ufw или firewalld (если файрвол активен)
3. Генерирует цепочку сертификатов X.509v3 RSA 2048 сроком на 10 лет: CA, Server с привязкой к IP в Subject Alternative Name, Client
4. Разворачивает контейнер Eviden KMS (`ghcr.io/cosmian/kms:5.28.0`) с нативным бинарным протоколом KMIP на порту 5696
5. Ждет, пока KMS реально начнет принимать TLS-соединения (не только открытие порта)
6. Проводит боевой автотест по протоколу KMIP: подключение по mTLS, генерация тестового ключа AES-256, чтение и удаление ключа

**Ожидаемый результат теста:**
```
🔐 KMIP Native Protocol Test
🔌 Connecting to KMS...
✅ Connected successfully!
🔑 Creating test AES-256 key...
✅ Key created: <UUID>
📥 Getting key back...
✅ Key retrieved: 32 bytes
🗑️  Destroying test key...
✅ Key destroyed
🎉 ALL TESTS PASSED!
✅ Native KMIP protocol работает отлично!
✅ Можно подключать Huawei Dorado!
```



## 2. Подключение Huawei Dorado к KMS

### Шаг 1. Проверьте синхронизацию времени
Убедитесь, что дата и время на СХД Huawei Dorado не отстают от времени на Linux-сервере.

Посмотреть время на сервере:
```bash
date
```
При сильном расхождении времени проверка TLS-сертификатов может не пройти (ошибка вроде `Certificate is not yet valid`).

### Шаг 2. Скачайте 3 файла сертификатов с KMS-сервера
После успешного выполнения `install.sh` в папке `~/kmip-certs/` появятся файлы для загрузки в Dorado. Заберите их через WinSCP, SCP или SFTP:

| Файл | Назначение |
|------|-----------|
| `~/kmip-certs/client.crt` | Клиентский сертификат для СХД |
| `~/kmip-certs/ca.crt` | Корневой сертификат (CA) |
| `~/kmip-certs/client.key` | Приватный ключ клиента |

Рядом также создается `~/kmip-certs/client_rsa.key` в традиционном формате PKCS#1 (`BEGIN RSA PRIVATE KEY`). Если прошивка Dorado не принимает `client.key`, загрузите `client_rsa.key`.

Посмотреть содержимое сертификатов:
```bash
cat ~/kmip-certs/ca.crt
cat ~/kmip-certs/client.crt
cat ~/kmip-certs/client.key
```

### Шаг 3. Настройте внешний сервер ключей в Huawei Dorado (DeviceManager)
В веб-интерфейсе Dorado перейдите в настройки шифрования: **Settings → Security → Key Service** или **Settings → Encryption**

1. Выберите **Enable the external key service**
2. Заполните поля:
   - **Server Type:** `General KMIP`
   - **Server IP / Address:** IP вашего KMS-сервера (например, `192.168.1.100`)
   - **Port:** `5696`
   - **Certificate File:** загрузите `client.crt`
   - **CA Certificate File:** загрузите `ca.crt`
   - **Private Key File:** загрузите `client.key` (или `client_rsa.key`)
3. Нажмите **Save / Apply**

Статус подключения должен перейти в **Normal / Connected**.

### Шаг 4. Проверьте доступность с Dorado (опционально)
Если есть доступ к командной строке на контроллере Dorado или соседней машине в сети:
```bash
nc -zv <KMS_IP> 5696
```
Должно быть: `Connection succeeded`




## 3. Проверка работы KMS

### Статус контейнера
```bash
# KMS запущен?
sudo docker ps | grep kms-server

# Логи (последние 20 строк):
sudo docker logs kms-server --tail 20

# Следить за логами в реальном времени:
sudo docker logs -f kms-server
```

### Проверить порт KMIP
```bash
ss -tlnp | grep 5696
```
Должно быть:
```
LISTEN  0  128  0.0.0.0:5696  0.0.0.0:*
```

### Ручной запуск теста KMIP
```bash
~/kmip-certs/venv/bin/python ~/kmip-certs/test.py
```




## 4. Тестирование шифрования на Dorado

### Создать тестовый зашифрованный LUN
В CLI Dorado или через GUI:
```bash
create lun name=test_encrypted pool=<pool_name> capacity=10 encrypted=yes
```
Если создался без ошибок — **KMS работает!**

### Проверить статус LUN
```bash
show lun general name=test_encrypted
```
Должно быть:
```
Encryption Status: Enabled
Key Source: External (KMIP)
```

### Проверить запросы в логах KMS
```bash
sudo docker logs kms-server | tail -30
```
В логах будут видны обращения от Dorado при создании и чтении ключей.





## 5. Управление KMS сервером

### Перезапуск
```bash
sudo docker restart kms-server
```

### Остановка / запуск
```bash
sudo docker stop kms-server
sudo docker start kms-server
```

### Смена IP-адреса KMS-сервера
Если виртуальной машине сменили IP-адрес, перегенерировать сертификаты под новый IP можно одной командой:
```bash
bash install.sh НОВЫЙ_IP
```
База уже созданных ключей в `~/kms-data` при этом сохраняется.

### Полное удаление
```bash
sudo docker stop kms-server
sudo docker rm kms-server
sudo docker rmi ghcr.io/cosmian/kms:5.28.0
rm -rf ~/kmip-certs ~/kms-config ~/kms-data
```





## 6. Частые проблемы

### ❌ Dorado не подключается к KMS
**Проверить:**
```bash
# 1. Порт открыт?
ss -tlnp | grep 5696

# 2. KMS запущен?
sudo docker ps | grep kms-server

# 3. Файрвол?
sudo ufw status | grep 5696
# или
sudo firewall-cmd --list-ports | grep 5696

# 4. Логи KMS:
sudo docker logs kms-server | grep -i error
```
**Возможные причины:**
- Файрвол блокирует порт 5696
- Неправильный IP адрес в настройках Dorado
- KMS контейнер остановлен

---

### ❌ "TLS handshake failed" / Ошибка сертификата
**Причина:** Неправильные сертификаты или несовпадение IP-адреса

**Решение:**
1. **Проверить что в Dorado загружены правильные файлы:**
   - CA Certificate File = `ca.crt` (НЕ `server.crt`!)
   - Certificate File = `client.crt`
   - Private Key File = `client.key` (или `client_rsa.key`)

2. **Проверить валидность сертификатов:**
```bash
# Проверить что client.crt подписан ca.crt:
openssl verify -CAfile ~/kmip-certs/ca.crt ~/kmip-certs/client.crt
```
Должно вывести: `client.crt: OK`

3. **Пересоздать сертификаты под точный IP-адрес KMS:**
```bash
bash install.sh <ТОЧНЫЙ_IP_KMS_СЕРВЕРА>
```

---

### ❌ "Connection timeout"
**Причина:** Сетевая недоступность между Dorado и KMS

**Решение:**
```bash
# 1. Проверить сеть:
ping -c 3 <KMS_IP>
nc -zv <KMS_IP> 5696

# 2. Проверить что KMS слушает на всех интерфейсах (0.0.0.0:5696):
ss -tlnp | grep 5696
```






## 7. Резервное копирование базы ключей
База ключей SQLite хранится на хосте в папке `~/kms-data/`. Для бэкапа достаточно скопировать эту директорию:
```bash
# Backup:
cp -r ~/kms-data ~/kms-backup-$(date +%Y%m%d)

# Или через Docker:
sudo docker cp kms-server:/data ~/kms-backup-$(date +%Y%m%d)

# Restore:
sudo docker cp ~/kms-backup-YYYYMMDD/. kms-server:/data/
sudo docker restart kms-server
```
**Важно:** Если KMS упадет, Dorado продолжает использовать уже закэшированные в памяти ключи для текущих дисков, но при перезагрузке СХД или создании новых зашифрованных LUN потребуется доступный KMS. Рекомендуется регулярно делать бэкап базы ключей.





## 8. Техническая информация
- **Протокол:** KMIP 1.2+ (native binary protocol over TLS, порт 5696)
- **База данных:** SQLite (в Docker-томе `~/kms-data`, внутри контейнера `/data`)
- **Сертификаты:** X.509v3 RSA 2048-bit (оптимально для совместимости с Huawei Dorado)
- **Лицензия:** Apache 2.0 (open source, бесплатный)
- **Docker образ:** `ghcr.io/cosmian/kms:5.28.0`

### Структура файлов после установки
```
~/kmip-certs/
├── ca.crt          # CA сертификат (загрузить в Dorado)
├── ca.key          # Приватный ключ CA
├── server.crt      # Серверный сертификат (используется KMS)
├── server.key      # Приватный ключ сервера (используется KMS)
├── client.crt      # Клиентский сертификат (загрузить в Dorado)
├── client.key      # Приватный ключ клиента PKCS#8 (загрузить в Dorado)
├── client_rsa.key  # Приватный ключ клиента PKCS#1 (запасной вариант)
├── venv/           # Изолированное Python-окружение с PyKMIP
└── test.py         # Тестовый скрипт проверки KMIP

~/kms-config/
└── kms.toml        # Конфигурация Eviden KMS

~/kms-data/
└── (база ключей SQLite)
```






## 9. Поддержка и диагностика
Если при подключении возникают ошибки, соберите вывод команд:
```bash
# Версия ОС:
cat /etc/os-release

# KMS статус:
sudo docker ps | grep kms-server

# Логи последних 50 строк:
sudo docker logs kms-server --tail 50 > kms-logs.txt

# IP-адрес сервера:
ip addr show

# Время на сервере (важно для TLS):
date
```
