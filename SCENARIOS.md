# Сценарии поломок — справочник

Каждый сценарий ломает одну AWS-вещь. Всё остальное — инстансы, приложение, ОС — работает исправно.
Цель: понять какой слой AWS-сети виноват и как это диагностировать через CLI.

```bash
./break.sh    # случайная поломка
./restore.sh  # восстановление
./status.sh   # стартовая точка диагностики
```

---

## Откуда брать ID ресурсов

Все ID создаются при `./create.sh` и сохраняются в файл `.state`.
Перед диагностикой выполни две команды — credentials из `.env` и ID ресурсов из `.state`:

```bash
source .env && source .state
```

После этого можно копировать команды из этого файла без изменений — `$ALB_ARN`, `$VPC_ID` и т.д. подставятся автоматически.

Посмотреть что внутри `.state`:

```bash
cat .state
```

Пример содержимого:

```
REGION=us-east-1
VPC_ID=vpc-02dcabb1b395b43d3
ALB_SG_ID=sg-0785b58c6fc1adf3a
EC2_SG_ID=sg-0bfb32ea608248080
ALB_ARN=arn:aws:elasticloadbalancing:...
TG_ARN=arn:aws:elasticloadbalancing:...
INSTANCE_1_ID=i-0ede99bebeb994308
INSTANCE_2_ID=i-0bc09aa1b0182839d
IGW_ID=igw-043d72c658cfed8b2
RTB_ID=rtb-097486b9d2462eb9a
KEY_NAME=troubleshoot-key
...
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

Security Group (SG) — виртуальный файрвол, привязанный к конкретному ресурсу.
У ALB своя SG, у EC2 своя SG — это два разных файрвола. Можно открыть EC2 и забыть открыть ALB.

Stateful: если входящий пакет разрешён, ответный выходит автоматически без отдельного правила.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Зависает, потом timeout — соединение не устанавливается |
| `curl http://$ALB_DNS` | `curl: (28) Connection timed out` |
| `./status.sh` → App Health Check | `FAIL` |
| Target Group health | Может показать `healthy` (ALB→EC2 работает, сломан только вход) |
| SSH на инстанс | Работает — другой SG, другой порт |

### Диагностика

```bash
source .env && source .state

# 1. Смотрим что в ALB SG — должно быть правило для порта 80
aws ec2 describe-security-groups \
    --group-ids $ALB_SG_ID \
    --query 'SecurityGroups[0].IpPermissions'
# Норма:  [{ "FromPort": 80, "IpRanges": [{"CidrIp": "0.0.0.0/0"}] }]
# Сломано: [] — пустой массив

# 2. ALB сам по себе жив?
aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].State'
# {"Code": "active"} — ALB жив, проблема не в нём

# 3. Таргеты здоровы? (ALB→EC2 работает внутри)
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --query 'TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}'
# Могут быть healthy — EC2 в порядке, проблема до ALB
```

Логика: timeout + ALB active + таргеты healthy = проблема до ALB = смотрим ALB SG.

### Решение

```bash
source .env && source .state

aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 80 --cidr "0.0.0.0/0"

# Или:
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

     Instance-1 / Instance-2  ← работают, просто заблокированы
```

### Концепция

EC2 SG может разрешать трафик не по IP, а по другой Security Group (SG reference).
Правило "разрешить от ALB SG" означает: пускать трафик от любого ресурса, у которого есть ALB SG.
Это удобно — не нужно знать IP ALB, который может меняться.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | `502 Bad Gateway` |
| `./status.sh` → Target health | `unhealthy` |
| SSH на инстанс | Работает — порт 22 не тронут |
| nginx на инстансе | Работает |

502 vs 503: **502** = ALB нашёл таргет, но не получил ответ. **503** = таргетов нет вообще.

### Диагностика

```bash
source .env && source .state

# 1. Получаем IP инстансов для SSH
aws ec2 describe-instances \
    --instance-ids $INSTANCE_1_ID $INSTANCE_2_ID \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,IP:PublicIpAddress,State:State.Name}' \
    --output table

# 2. 502 → смотрим target health
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --query 'TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}'
# State: unhealthy, Reason: Target.FailedHealthChecks

# 3. Смотрим EC2 SG — есть ли правило для порта 80?
aws ec2 describe-security-groups \
    --group-ids $EC2_SG_ID \
    --query 'SecurityGroups[0].IpPermissions'
# Норма:  правило с "UserIdGroupPairs" содержащим ALB SG ID
# Сломано: только правило для порта 22, порта 80 нет

# 4. SSH → проверяем что приложение живое на инстансе
ssh -i $KEY_NAME.pem -o IdentitiesOnly=yes ec2-user@<IP из шага 1>
sudo systemctl status nginx        # active — nginx работает
curl -s localhost/health           # ok — Flask работает
# Вывод: проблема не в приложении, а в сети перед ним
```

Логика: 502 + unhealthy таргеты + приложение живое = EC2 SG не пускает ALB.

### Решение

```bash
source .env && source .state

aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG_ID \
    --protocol tcp --port 80 \
    --source-group $ALB_SG_ID

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

Target Group — список бэкендов куда ALB шлёт трафик. Каждый таргет проходит health checks.
Регистрация инстансов в TG — отдельная операция, не связанная с их запуском.
Если таргетов нет — ALB возвращает 503.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | `503 Service Unavailable` |
| `./status.sh` → Target health | Таблица пустая или статус `unused` |
| SSH на инстанс | Работает |
| nginx/Flask на инстансе | Работает |

### Диагностика

```bash
source .env && source .state

# 1. 503 → смотрим target group — кто там зарегистрирован
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --query 'TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}'
# [] — пустой массив. Инстансов нет.

# 2. Инстансы сами по себе живые?
aws ec2 describe-instances \
    --instance-ids $INSTANCE_1_ID $INSTANCE_2_ID \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name}' \
    --output table
# Оба running — инстансы в порядке, просто не в TG

# 3. Listener настроен правильно?
aws elbv2 describe-listeners \
    --load-balancer-arn $ALB_ARN \
    --query 'Listeners[*].{Port:Port,Action:DefaultActions[0].Type}'
# forward — правильно, проблема именно в TG
```

Логика: 503 + пустой TG + живые инстансы = инстансы не зарегистрированы в Target Group.

### Решение

```bash
source .env && source .state

aws elbv2 register-targets \
    --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_1_ID Id=$INSTANCE_2_ID

# Или:
./restore.sh
```

---

## Сценарий 4 — Route Table: удалён маршрут до IGW

### Что сломано

Из Route Table удалена запись `0.0.0.0/0 → IGW`.
Подсеть знает только о внутренней сети VPC, но не знает как выйти в интернет.

```
Internet
    │
[ IGW ]  ← существует, прицеплен к VPC
    │
    ?  ← маршрута нет, пакеты некуда слать

┌──────────────────────────────────┐
│ Route Table                      │
│ 10.0.0.0/16 → local      ✓      │
│ 0.0.0.0/0   → igw   УДАЛЕНО ✗  │  ← ЗДЕСЬ СЛОМАНО
└──────────────────────────────────┘
        │                │
   subnet-a          subnet-b
   Instance-1        Instance-2
```

### Концепция

Route Table — таблица маршрутизации подсети. Без маршрута `0.0.0.0/0 → IGW` подсеть изолирована внутри VPC: трафик снаружи не заходит, изнутри не выходит.

IGW (Internet Gateway) — точка входа/выхода между VPC и интернетом. Он на месте, но подсеть о нём не знает.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Timeout — соединение не устанавливается |
| SSH на инстанс | Timeout |
| `./status.sh` → Target health | `unhealthy` |

### Диагностика

```bash
source .env && source .state

# 1. Полный timeout везде → проблема на сетевом уровне
# 2. Смотрим маршруты в Route Table
aws ec2 describe-route-tables \
    --route-table-ids $RTB_ID \
    --query 'RouteTables[0].Routes'
# Норма:  содержит {"DestinationCidrBlock":"0.0.0.0/0","GatewayId":"igw-xxx","State":"active"}
# Сломано: только {"DestinationCidrBlock":"10.0.0.0/16","GatewayId":"local"}

# 3. IGW существует и прицеплен к VPC?
aws ec2 describe-internet-gateways \
    --internet-gateway-ids $IGW_ID \
    --query 'InternetGateways[0].Attachments'
# [{"State":"available","VpcId":"vpc-xxx"}] — IGW в порядке, виноват маршрут
```

Логика: полный timeout + IGW прицеплен + маршрута нет = Route Table.

### Решение

```bash
source .env && source .state

aws ec2 create-route \
    --route-table-id $RTB_ID \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id $IGW_ID

# Или:
./restore.sh
```

---

## Сценарий 5 — IGW: отцеплен от VPC

### Что сломано

Internet Gateway отцеплен от VPC. Маршрут в Route Table на IGW остался — но IGW больше не работает.

```
Internet
    │
[ IGW ]  ← существует, но НЕ прицеплен к VPC  ← ЗДЕСЬ СЛОМАНО

┌──────────────────────────────────┐
│ Route Table                      │
│ 0.0.0.0/0 → igw ✓ (маршрут есть)│  ← маршрут есть, но IGW не работает
└──────────────────────────────────┘
        │
   subnet-a / subnet-b
   Instance-1 / Instance-2
```

### Концепция

IGW выполняет две функции:
1. Маршрутизирует трафик между VPC и интернетом
2. NAT: заменяет приватный IP инстанса на публичный (и обратно)

Без прицепленного IGW маршрут `0.0.0.0/0 → igw-xxx` — "битая ссылка". Route Table выглядит правильно, IGW существует — но связи нет. Это делает сценарий коварным.

### Симптомы

Идентичны сценарию 4 — полный timeout везде.

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Timeout |
| SSH на инстанс | Timeout |
| Route Table | Выглядит правильно — маршрут есть! |

### Диагностика

```bash
source .env && source .state

# 1. Полный timeout + Route Table выглядит нормально → копаем IGW
# 2. Смотрим Route Table — маршрут есть?
aws ec2 describe-route-tables \
    --route-table-ids $RTB_ID \
    --query 'RouteTables[0].Routes'
# 0.0.0.0/0 → igw-xxx — маршрут на месте

# 3. IGW прицеплен к VPC?
aws ec2 describe-internet-gateways \
    --internet-gateway-ids $IGW_ID \
    --query 'InternetGateways[0].Attachments'
# Норма:  [{"State":"available","VpcId":"vpc-xxx"}]
# Сломано: [] — пустой массив, IGW ни к чему не прицеплен
```

Отличие от сценария 4: Route Table правильный → копаем дальше → IGW без Attachments.

### Решение

```bash
source .env && source .state

aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID

# Или:
./restore.sh
```

---

## Сценарий 6 — Network ACL: явный DENY на порт 80

### Что сломано

В Network ACL добавлено правило `rule 1: DENY TCP 80 inbound`.
Security Groups не тронуты — они разрешают трафик. Но NACL блокирует на уровень выше.

```
Internet → IGW → Route Table → Subnet
                                  │
                         ┌────────▼────────┐
                         │  Network ACL    │
                         │  Rule  1: DENY  │  ← ЗДЕСЬ СЛОМАНО
                         │  TCP :80        │
                         │  Rule 100: ALLOW│
                         │  all traffic    │
                         └────────┬────────┘
                                  │ (отброшен, до SG не доходит)
                                  ✗
               ┌──────────────────────────────┐
               │ ALB SG: port 80 открыт ✓     │  ← правила правильные,
               └──────────────────────────────┘     но трафик не доходит
               ┌──────────────────────────────┐
               │ EC2 SG: port 80 открыт ✓     │
               └──────────────────────────────┘
```

### Концепция

**Security Group vs Network ACL:**

| | Security Group | Network ACL |
|--|---------------|-------------|
| Уровень | Ресурс (EC2, ALB) | Подсеть |
| Stateful | Да — ответ выходит автоматически | Нет — нужны правила для входящего И исходящего |
| Правила | Только ALLOW | ALLOW и DENY |
| Порядок | Все правила суммируются | По номеру — первое совпадение выигрывает |
| По умолчанию | Запрещено всё входящее | Разрешено всё |

NACL обрабатывается **до** Security Group. DENY в NACL — трафик не дойдёт до SG.

Это самый коварный сценарий: SG выглядит правильно — а трафик не идёт.

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Timeout |
| SSH на инстанс | **Работает** — порт 22 в NACL не заблокирован |
| ALB SG и EC2 SG | Выглядят правильно — порт 80 открыт |

SSH работает, а HTTP нет, при этом SG открыты → думаем о NACL.

### Диагностика

```bash
source .env && source .state

# 1. HTTP timeout, SSH работает, SG открыты → смотрим NACL
aws ec2 describe-network-acls \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
    --query 'NetworkAcls[0].Entries[?Egress==`false`]' \
    --output table
# Норма:  одно правило RuleNumber=100, RuleAction=allow
# Сломано: RuleNumber=1, RuleAction=deny, Protocol=6(TCP), Port=80
#          это правило выполняется РАНЬШЕ чем allow — трафик дропается

# 2. Для сравнения — смотрим SG, они в порядке
aws ec2 describe-security-groups \
    --group-ids $ALB_SG_ID \
    --query 'SecurityGroups[0].IpPermissions'
# Порт 80 открыт — SG не виноват
```

Логика: HTTP timeout + SSH работает + SG правильный = NACL.

### Решение

```bash
source .env && source .state

# Узнаём NACL ID
NACL_ID=$(aws ec2 describe-network-acls \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
    --query 'NetworkAcls[0].NetworkAclId' \
    --output text)

# Удаляем правило #1
aws ec2 delete-network-acl-entry \
    --network-acl-id $NACL_ID \
    --ingress \
    --rule-number 1

# Или:
./restore.sh
```

---

## Сценарий 7 — Spot Interruption: Instance-1 остановлен

### Что сломано

Instance-1 остановлен. Имитирует Spot interruption — AWS забирает ёмкость обратно.
Instance-2 работает. ALB перестаёт слать трафик на Instance-1.

```
Internet → ALB SG → ALB
                     │
              ┌──────▼──────┐
              │ Target Group │
              │ Instance-1  ✗│  ← stopped, unhealthy
              │ Instance-2  ✓│  ← running, healthy
              └─────────────┘
                     │
              Instance-2 обслуживает весь трафик
```

### Концепция

Spot Instance — AWS продаёт свободные мощности со скидкой до 90%.
Когда мощности нужны AWS — он даёт 2 минуты и останавливает инстанс.

В нашем сетапе `persistent` + `stop`: инстанс остановится, данные на EBS сохранятся, AWS перезапустит когда появится ёмкость.

ALB автоматически убирает упавший инстанс из ротации — в этом смысл двух AZ.

Статус spot request показывает причину остановки:
- `instance-stopped-by-user` — остановил пользователь, AWS не перезапустит
- `marked-for-stop` — AWS прерывает прямо сейчас (есть 2 минуты)

### Симптомы

| Что | Результат |
|-----|-----------|
| Браузер → ALB DNS | Работает (через Instance-2) |
| `./status.sh` → Target health Instance-1 | `unhealthy` или `unused` |
| `./status.sh` → Target health Instance-2 | `healthy` |
| SSH на Instance-1 | Timeout |
| SSH на Instance-2 | Работает |

### Диагностика

```bash
source .env && source .state

# 1. Приложение работает, но один таргет упал → смотрим target health
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --query 'TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}'
# Instance-1: unhealthy / unused
# Instance-2: healthy

# 2. Состояние инстансов
aws ec2 describe-instances \
    --instance-ids $INSTANCE_1_ID $INSTANCE_2_ID \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Lifecycle:InstanceLifecycle}' \
    --output table
# Instance-1: stopped, spot
# Instance-2: running, spot

# 3. Почему остановлен — смотрим spot request
aws ec2 describe-spot-instance-requests \
    --filters "Name=instance-id,Values=$INSTANCE_1_ID" \
    --query 'SpotInstanceRequests[0].{State:State,Status:Status.Code}'
# instance-stopped-by-user → остановил пользователь (или имитация interruption)
# marked-for-stop           → AWS прерывает сейчас
```

Логика: один таргет unhealthy + инстанс stopped + lifecycle=spot = Spot interruption.

### Решение

```bash
source .env && source .state

aws ec2 start-instances --instance-ids $INSTANCE_1_ID

# Или:
./restore.sh
```

---

## Шпаргалка: симптом → сценарий

```
Браузер timeout (соединение не устанавливается)
├── SSH тоже не работает → проблема глубже в сети
│   ├── describe-route-tables  → нет маршрута 0.0.0.0/0?  → сц. 4
│   └── describe-internet-gateways → Attachments пустой?  → сц. 5
│
└── SSH работает, SG открыты → NACL
    └── describe-network-acls → есть DENY rule?           → сц. 6

└── SSH работает, SG пустой (нет inbound 80 на ALB SG)   → сц. 1

Браузер получает HTTP-ошибку
├── HTTP 502 Bad Gateway
│   └── EC2 SG не пускает ALB                            → сц. 2
│
└── HTTP 503 Service Unavailable
    └── Target Group пустой или все unhealthy             → сц. 3

Приложение работает, но один инстанс выпал
└── describe-target-health → один unhealthy              → сц. 7
```

## Общий алгоритм диагностики

```bash
source .env && source .state

# Шаг 1 — общая картина
./status.sh

# Шаг 2 — какой HTTP-код возвращает ALB?
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' --output text)
curl -sv http://$ALB_DNS/health 2>&1 | grep "< HTTP"

# Шаг 3 — доступен ли инстанс по SSH?
IP_1=$(aws ec2 describe-instances --instance-ids $INSTANCE_1_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh -i $KEY_NAME.pem -o IdentitiesOnly=yes ec2-user@$IP_1

# Дальше — по дереву симптомов выше
```
