# Сценарии поломок — справочник

Каждый сценарий ломает одну AWS-вещь. Всё остальное — инстансы, приложение, ОС — работает исправно.
Цель: понять какой слой AWS-сети виноват и как это диагностировать через CLI.

```
./break.sh    # случайная поломка
./restore.sh  # восстановление
./status.sh   # стартовая точка диагностики
```

---

## Нормальное состояние (для сравнения)

```
Internet
    │  TCP :80
    ▼
┌─────────────────────────────────────┐
│ ALB Security Group                  │
│ INBOUND: 0.0.0.0/0 → port 80 ✓     │
└─────────────────┬───────────────────┘
                  │
                  ▼
              [ ALB ]
                  │  TCP :80
                  ▼
┌─────────────────────────────────────┐
│ EC2 Security Group                  │
│ INBOUND: ALB SG → port 80 ✓        │
│ INBOUND: 0.0.0.0/0 → port 22 ✓    │
└──────────┬──────────────┬───────────┘
           │              │
     Instance-1      Instance-2
     nginx→Flask     nginx→Flask
```

Здоровый `./status.sh` показывает:
- ALB State: `active`
- Оба таргета: `healthy`
- App Health Check: `OK`

---

## Сценарий 1 — ALB SG: убран порт 80

### Что сломано

Из ALB Security Group удалено inbound-правило `0.0.0.0/0 → TCP 80`.
ALB физически существует и работает, но не может принять входящий трафик из интернета.

```
Internet
    │  TCP :80
    ▼
┌─────────────────────────────────────┐
│ ALB Security Group                  │
│ INBOUND: (пусто) ✗  ← ЗДЕСЬ СЛОМАНО│
└─────────────────────────────────────┘
    (трафик до ALB не доходит)

              [ ALB ]  ← работает, но изолирован
                  │
           Instance-1 / Instance-2  ← работают
```

### Концепция

Security Group — это stateful межсетевой экран уровня ресурса.
У ALB своя SG, отдельная от SG инстансов. Можно открыть EC2 и забыть открыть ALB — типичная ошибка.

Stateful означает: если входящий пакет разрешён, ответный выходит автоматически без отдельного outbound-правила.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Зависает, потом timeout (соединение не устанавливается) |
| `curl http://<ALB_DNS>` | `curl: (28) Connection timed out` |
| `./status.sh` → App Health Check | `FAIL` |
| Target Group health | Может показать `healthy` (ALB → EC2 работает, сломан только вход) |
| SSH на инстанс | Работает (другой SG, другой порт) |

### Диагностика

```bash
# 1. Смотрим что вообще есть в ALB SG
aws ec2 describe-security-groups \
    --group-ids <ALB_SG_ID> \
    --query 'SecurityGroups[0].IpPermissions'

# Нормальный результат — должно быть:
# [{ "FromPort": 80, "ToPort": 80, "IpRanges": [{"CidrIp": "0.0.0.0/0"}] }]
# Сломанный результат — пустой массив: []

# 2. Проверяем ALB сам по себе
aws elbv2 describe-load-balancers \
    --load-balancer-arns <ALB_ARN> \
    --query 'LoadBalancers[0].State'
# Вернёт {"Code": "active"} — ALB жив, проблема не в нём

# 3. Target group здоровье (ALB→EC2 работает)
aws elbv2 describe-target-health \
    --target-group-arn <TG_ARN>
# Таргеты могут быть healthy — это подтверждает что EC2 в порядке
```

Логика: таймаут при подключении к ALB + здоровые таргеты = проблема до ALB = SG на ALB.

### Решение

```bash
# Вернуть правило
aws ec2 authorize-security-group-ingress \
    --group-id <ALB_SG_ID> \
    --protocol tcp --port 80 --cidr "0.0.0.0/0"

# Или одной командой:
./restore.sh
```

---

## Сценарий 2 — EC2 SG: убрано правило ALB→EC2

### Что сломано

Из EC2 Security Group удалено inbound-правило `ALB SG → TCP 80`.
ALB принимает запросы из интернета, но не может достучаться до инстансов.

```
Internet
    │  TCP :80
    ▼
┌─────────────────────────────────────┐
│ ALB Security Group                  │
│ INBOUND: 0.0.0.0/0 → port 80 ✓     │
└─────────────────┬───────────────────┘
                  │
              [ ALB ]  ← получает запрос
                  │  TCP :80
                  ▼
┌─────────────────────────────────────┐
│ EC2 Security Group                  │
│ INBOUND: (ALB SG → 80 удалено) ✗   │  ← ЗДЕСЬ СЛОМАНО
└─────────────────────────────────────┘
    (ALB не может достучаться до EC2)

     Instance-1 / Instance-2  ← работают, просто заблокированы
```

### Концепция

EC2 SG разрешает трафик не только по IP/CIDR, но и **по другой Security Group** (`source-group`).
Это называется SG reference — вместо "разрешить с IP 10.0.x.x" говоришь "разрешить от всего что в ALB SG".
Это гибче и безопаснее: не нужно знать IP ALB, который может меняться.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | `502 Bad Gateway` — ALB достиг EC2, но EC2 не ответил |
| `curl http://<ALB_DNS>` | HTTP 502 |
| `./status.sh` → Target health | `unhealthy` — health checks от ALB тоже блокируются |
| SSH на инстанс | Работает (порт 22 отдельным правилом, оно не тронуто) |

### Диагностика

```bash
# 1. Видим 502 — значит ALB живой, проблема за ним
# 2. Смотрим target health
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
# State: unhealthy, Reason: Target.FailedHealthChecks
# ALB пытается достучаться до EC2 на порту 80 — не может

# 3. Смотрим EC2 SG
aws ec2 describe-security-groups \
    --group-ids <EC2_SG_ID> \
    --query 'SecurityGroups[0].IpPermissions'
# Нормально: UserIdGroupPairs с ALB SG ID
# Сломано: только правило для порта 22, правила для порта 80 нет

# 4. SSH на инстанс и проверяем что nginx живой
ssh -i troubleshoot-key.pem -o IdentitiesOnly=yes ec2-user@<IP>
sudo systemctl status nginx   # active (running) — nginx работает
curl localhost/health          # ok — Flask тоже работает
# Вывод: проблема не в приложении, а в сети перед ним
```

Логика: 502 от ALB + unhealthy таргеты + приложение на инстансе живое = EC2 SG блокирует ALB.

### Решение

```bash
aws ec2 authorize-security-group-ingress \
    --group-id <EC2_SG_ID> \
    --protocol tcp --port 80 \
    --source-group <ALB_SG_ID>

# Или:
./restore.sh
```

---

## Сценарий 3 — Target Group: инстансы дерегистрированы

### Что сломано

Оба инстанса удалены из Target Group. ALB не знает куда форвардить запросы.
Инстансы запущены, приложение работает — но ALB о них не знает.

```
Internet → ALB SG → ALB
                     │
              ┌──────▼──────┐
              │ Target Group │  ← пустой, инстансов нет
              └─────────────┘

     Instance-1  Instance-2   ← живые, но ALB их не видит
```

### Концепция

Target Group — это список бэкендов куда ALB шлёт трафик.
Каждый таргет проходит health checks. Если таргетов нет вообще — ALB возвращает 503.
Регистрация/дерегистрация инстансов — отдельная операция от их запуска/остановки.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | `503 Service Unavailable` |
| `curl http://<ALB_DNS>` | HTTP 503 |
| `./status.sh` → Target health | Таблица пустая или `unused` |
| SSH на инстанс | Работает |
| nginx/Flask на инстансе | Работает |

Ключевое отличие от сценария 2: **503 вместо 502**.
- 502 = ALB нашёл таргет, но тот не ответил
- 503 = ALB вообще не нашёл живых таргетов

### Диагностика

```bash
# 1. 503 от ALB → смотрим target group
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
# Результат: пустой массив [] или статус "unused"

# 2. Проверяем что инстансы живые
aws ec2 describe-instances \
    --instance-ids <ID1> <ID2> \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name}'
# Оба running — инстансы в порядке

# 3. Смотрим listener — куда ALB форвардит
aws elbv2 describe-listeners --load-balancer-arn <ALB_ARN>
# default action: forward to TG — всё правильно, проблема в TG
```

Логика: 503 + пустой target group + живые инстансы = инстансы не зарегистрированы в TG.

### Решение

```bash
aws elbv2 register-targets \
    --target-group-arn <TG_ARN> \
    --targets Id=<INSTANCE_1_ID> Id=<INSTANCE_2_ID>

# Или:
./restore.sh
```

---

## Сценарий 4 — Route Table: удалён маршрут до IGW

### Что сломано

Из Route Table удалена запись `0.0.0.0/0 → IGW`.
Подсети знают только о внутренней сети VPC (`10.0.0.0/16`), но не знают как выйти в интернет.

```
Internet
    │
[ IGW ]  ← существует, прицеплен к VPC
    │
    ?  ← маршрута нет, пакеты некуда слать

┌──────────────────────────────────┐
│ Route Table                      │
│ 10.0.0.0/16 → local  ✓          │
│ 0.0.0.0/0   → igw-xxx  УДАЛЕНО ✗│  ← ЗДЕСЬ СЛОМАНО
└──────────────────────────────────┘
        │                │
   subnet-a          subnet-b
   Instance-1        Instance-2
```

### Концепция

Route Table — таблица маршрутизации подсети. Без маршрута `0.0.0.0/0 → IGW` подсеть **публичной не является** — она изолирована внутри VPC. Трафик снаружи не заходит, трафик изнутри не выходит.

Отличие от сценария 5 (IGW detach): IGW существует и прицеплен к VPC, но подсеть о нём не знает.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Timeout (соединение не устанавливается) |
| SSH на инстанс | Timeout |
| ALB State | Может стать `active` но недоступен |
| Target health | `unhealthy` (ALB health checks тоже не доходят) |

### Диагностика

```bash
# 1. Полный timeout везде — значит проблема на сетевом уровне (не в приложении)
# 2. Смотрим route table нашей подсети
aws ec2 describe-route-tables --route-table-ids <RTB_ID>
# Нормально: Routes содержит {"DestinationCidrBlock":"0.0.0.0/0","GatewayId":"igw-xxx"}
# Сломано: только {"DestinationCidrBlock":"10.0.0.0/16","GatewayId":"local"}

# 3. Проверяем IGW — он на месте?
aws ec2 describe-internet-gateways --internet-gateway-ids <IGW_ID>
# IGW существует и Attachments показывает наш VPC — значит IGW не виноват
# Проблема именно в маршруте
```

Логика: полный timeout (не 502, не 503) + IGW прицеплен + маршрута нет = Route Table.

### Решение

```bash
aws ec2 create-route \
    --route-table-id <RTB_ID> \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id <IGW_ID>

# Или:
./restore.sh
```

---

## Сценарий 5 — IGW: отцеплен от VPC

### Что сломано

Internet Gateway отцеплен от VPC (`detach-internet-gateway`).
Маршрут в Route Table на IGW остался — но IGW больше не обслуживает этот VPC.

```
Internet
    │
[ IGW ]  ← существует, но НЕ прицеплен к VPC  ← ЗДЕСЬ СЛОМАНО

┌──────────────────────────────────┐
│ Route Table                      │
│ 0.0.0.0/0 → igw-xxx  ✓ (есть)  │  ← маршрут есть, но IGW не работает
└──────────────────────────────────┘
        │
   subnet-a / subnet-b
   Instance-1 / Instance-2
```

### Концепция

IGW выполняет две функции:
1. Маршрутизирует трафик между VPC и интернетом
2. Делает NAT: заменяет приватный IP инстанса на публичный (и обратно)

Без прицепленного IGW маршрут `0.0.0.0/0 → igw-xxx` становится "битой ссылкой" — адресат есть, но не работает.

Это коварный сценарий: Route Table выглядит корректно, IGW существует — но связи нет.

### Симптомы

Идентичны сценарию 4: полный timeout и SSH, и HTTP.

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Timeout |
| SSH на инстанс | Timeout |
| Route Table | Выглядит правильно (маршрут есть!) |

### Диагностика

```bash
# 1. Полный timeout + Route Table выглядит нормально
# 2. Проверяем IGW детально — смотрим Attachments
aws ec2 describe-internet-gateways --internet-gateway-ids <IGW_ID>
# Нормально: "Attachments": [{"State": "available", "VpcId": "vpc-xxx"}]
# Сломано:   "Attachments": []  ← пустой массив, IGW ни к чему не прицеплен

# 3. Для сравнения — маршрут в Route Table есть:
aws ec2 describe-route-tables --route-table-ids <RTB_ID>
# 0.0.0.0/0 → igw-xxx  — маршрут на месте, но IGW не работает
```

Отличие от сценария 4: Route Table правильный → копаем дальше → IGW без Attachments.

### Решение

```bash
aws ec2 attach-internet-gateway \
    --internet-gateway-id <IGW_ID> \
    --vpc-id <VPC_ID>

# Или:
./restore.sh
```

---

## Сценарий 6 — Network ACL: явный DENY на порт 80

### Что сломано

В дефолтный Network ACL добавлено правило `rule 1: DENY TCP 80 inbound`.
Security Groups при этом не тронуты — они разрешают трафик. Но NACL блокирует раньше.

```
Internet → IGW → Route Table → Subnet
                                  │
                         ┌────────▼────────┐
                         │  Network ACL    │
                         │  Rule 1: DENY   │  ← ЗДЕСЬ СЛОМАНО
                         │  TCP :80        │
                         │  Rule 100: ALLOW│
                         │  all            │
                         └─────────────────┘
                                  │
                              (отброшен)

               ┌──────────────────────────────┐
               │ ALB Security Group: port 80 ✓ │  ← правила открыты,
               └──────────────────────────────┘     но трафик до SG
               ┌──────────────────────────────┐     не доходит
               │ EC2 Security Group: port 80 ✓ │
               └──────────────────────────────┘
```

### Концепция

**Security Group vs Network ACL — ключевые различия:**

| | Security Group | Network ACL |
|--|---------------|-------------|
| Уровень | Ресурс (EC2, ALB) | Подсеть |
| Stateful | Да — ответ выходит автоматически | Нет — нужны правила для inbound И outbound |
| Правила | Только ALLOW | ALLOW и DENY |
| Порядок | Все правила применяются | Numbered, первое совпадение выигрывает |
| По умолчанию | Запрещено всё входящее | Разрешено всё |

NACL обрабатывается **до** Security Group. Если NACL говорит DENY — до SG пакет не дойдёт.

Это самый коварный сценарий: SG выглядит правильно, всё открыто — а трафик не идёт.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Timeout |
| SSH на инстанс | Работает (порт 22 не заблокирован в NACL) |
| Security Groups | Выглядят правильно — порт 80 открыт |
| Target health | Unhealthy (health checks от ALB тоже блокируются) |

### Диагностика

```bash
# 1. Timeout на HTTP, но SSH работает — SG открыты
# 2. Смотрим SG — всё правильно. Копаем выше по стеку
# 3. Смотрим Network ACL нашего VPC
aws ec2 describe-network-acls \
    --filters "Name=vpc-id,Values=<VPC_ID>" "Name=default,Values=true" \
    --query 'NetworkAcls[0].Entries'

# Нормально: одно правило rule=100 ALLOW all + rule=32767 DENY all (implicit)
# Сломано: rule=1 DENY TCP 80 ПЕРЕД rule=100 ALLOW all

# Правила применяются по номеру — rule 1 срабатывает раньше rule 100
```

Логика: HTTP timeout + SSH работает + SG открыты = NACL или что-то выше (IGW/RTB).
Проверяем NACL — видим DENY с низким номером правила.

### Решение

```bash
aws ec2 delete-network-acl-entry \
    --network-acl-id <NACL_ID> \
    --ingress \
    --rule-number 1

# Или:
./restore.sh
```

---

## Сценарий 7 — Spot Interruption: Instance-1 остановлен

### Что сломано

Instance-1 остановлен (`stop-instances`). Имитирует Spot interruption — AWS забирает ёмкость.
Instance-2 работает нормально. ALB должен перестать слать трафик на Instance-1.

```
Internet → ALB SG → ALB
                     │
              ┌──────▼──────┐
              │ Target Group │
              │ Instance-1  ✗│  ← stopped, unhealthy
              │ Instance-2  ✓│  ← running, healthy
              └─────────────┘
                     │
              Instance-2 обслуживает всё
```

### Концепция

**Spot Instance** — AWS продаёт свободную ёмкость со скидкой до 90%. Когда эта ёмкость нужна AWS — он даёт 2 минуты на завершение работы и останавливает (или терминирует) инстанс.

В нашем сетапе:
- `SpotInstanceType: persistent` — запрос остаётся открытым, AWS перезапустит когда будет ёмкость
- `InstanceInterruptionBehavior: stop` — инстанс останавливается, данные на EBS сохраняются

ALB автоматически перестаёт слать трафик на нездоровый таргет — это и есть смысл multi-AZ.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Работает (через Instance-2) |
| App Health Check | OK |
| Target health Instance-1 | `unused` или `unhealthy` |
| Target health Instance-2 | `healthy` |
| SSH на Instance-1 | Timeout (инстанс остановлен) |
| SSH на Instance-2 | Работает |

### Диагностика

```bash
# 1. Приложение работает, но что-то не так
# 2. Смотрим target health
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
# Instance-1: unhealthy / unused
# Instance-2: healthy

# 3. Смотрим состояние инстансов
aws ec2 describe-instances \
    --instance-ids <INSTANCE_1_ID> <INSTANCE_2_ID> \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Type:InstanceLifecycle}'
# Instance-1: stopped, spot
# Instance-2: running, spot

# 4. Проверяем spot request
aws ec2 describe-spot-instance-requests \
    --filters "Name=instance-id,Values=<INSTANCE_1_ID>"
# Status: instance-stopped
```

Логика: один таргет unhealthy + инстанс stopped + spot lifecycle = Spot interruption.

### Решение

```bash
aws ec2 start-instances --instance-ids <INSTANCE_1_ID>

# Или:
./restore.sh
```

---

## Шпаргалка: что даёт какой симптом

```
Браузер timeout (соединение не устанавливается)
├── SSH тоже не работает → проблема на уровне сети до инстансов
│   ├── Route Table: нет маршрута 0.0.0.0/0        (сц. 4)
│   └── IGW: отцеплен от VPC                        (сц. 5)
│
└── SSH работает → трафик до инстансов доходит, но порт 80 блокируется
    ├── SG на ALB закрыт (нет inbound 80)           (сц. 1)
    └── NACL: DENY rule для порта 80                 (сц. 6)
        (проверяй NACL когда SG выглядит правильно)

Браузер получает HTTP-ответ с ошибкой
├── HTTP 502 Bad Gateway
│   └── ALB не может достучаться до EC2             (сц. 2)
│       (EC2 SG не пускает ALB)
│
└── HTTP 503 Service Unavailable
    └── Target Group пустой или все таргеты unhealthy (сц. 3)

Приложение работает, но один инстанс выпал
└── Spot interruption / инстанс остановлен           (сц. 7)
```

## Порядок диагностики (общий алгоритм)

```
1. ./status.sh                          # общая картина
2. curl -v http://<ALB_DNS>/health      # какой HTTP-код?
3. ssh ... ec2-user@<IP>                # доступен ли инстанс?

Если timeout:
  4a. describe-route-tables             # есть маршрут 0.0.0.0/0?
  4b. describe-internet-gateways        # IGW прицеплен к VPC?
  4c. describe-network-acls             # нет ли DENY в NACL?
  4d. describe-security-groups (ALB SG) # открыт порт 80?

Если 502:
  4. describe-target-health             # unhealthy?
  5. ssh → curl localhost/health        # приложение живое?
  6. describe-security-groups (EC2 SG)  # есть правило от ALB SG?

Если 503:
  4. describe-target-health             # пустой TG?
  5. describe-instances                 # инстансы running?
```
