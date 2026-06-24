# AWS Troubleshooting Lab

Двухзвенное приложение на AWS для практики траблшутинга AWS-инфраструктуры.
ALB → 2x EC2 t4g.micro (Spot, ARM) → nginx → Flask → SQLite.

## Быстрый старт

**1.** Создай файл `.env` в корне репозитория:

```bash
AWS_ACCESS_KEY_ID=AKIA...        # из ~/.aws/credentials или AWS Console → IAM → Users → Security credentials
AWS_SECRET_ACCESS_KEY=...        # из того же места — показывается только при создании ключа
AWS_REGION=us-east-1             # регион для деплоя
```

**2.** Запусти:

```bash
./create.sh
```

## Архитектура

```
                        Internet
                           │
                    ┌──────▼──────┐
                    │  ALB SG     │  port 80 from 0.0.0.0/0
                    │             │
                    │     ALB     │  troubleshoot-alb
                    └──────┬──────┘
                           │  port 80 (from ALB SG only)
              ┌────────────┴────────────┐
              │                         │
       ┌──────▼──────┐           ┌──────▼──────┐
       │   EC2 SG    │           │   EC2 SG    │  port 22 from 0.0.0.0/0
       │             │           │             │
       │ Instance-1  │           │ Instance-2  │
       │ us-east-1a  │           │ us-east-1b  │
       │ t4g.micro   │           │ t4g.micro   │
       │   (Spot)    │           │   (Spot)    │
       │             │           │             │
       │ nginx :80   │           │ nginx :80   │
       │ Flask :5000 │           │ Flask :5000 │
       │ SQLite      │           │ SQLite      │
       └─────────────┘           └─────────────┘
       subnet-a (10.0.1.0/24)   subnet-b (10.0.2.0/24)
                    └────────────┬────────────┘
                          Route Table
                      0.0.0.0/0 → IGW
                                │
                    Internet Gateway (IGW)
```

## Стоимость

| Состояние | Что платим | Сумма |
|-----------|-----------|-------|
| **Running** | 2x t4g.micro spot + 2x EBS + 2x IPv4 + ALB | **~$0.025/час** (~$0.60/день) |
| **Stopped** | 2x EBS 8GB + ALB (удаляется stop.sh) | **~$1.28/мес** |
| **Deleted** | ничего | **$0** |

Детализация когда running:

| Ресурс | Цена |
|--------|------|
| 2x t4g.micro Spot | ~$0.0025/час × 2 = $0.005/час |
| 2x EBS gp3 8GB | ~$0.0009/час × 2 = $0.002/час |
| 2x Public IPv4 | $0.005/час × 2 = $0.010/час |
| ALB | $0.008/час |

> **Важно:** `stop.sh` удаляет ALB (экономит ~$5.76/мес). `start.sh` его пересоздаёт (~2-3 мин).
> Если не используешь — запускай `./delete.sh`, не `./stop.sh`.

## Требования

- AWS CLI настроен (`aws configure` или env vars `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)
- Регион по умолчанию: `us-east-1`. Переопределить: `export AWS_REGION=eu-west-1`

## Скрипты

```bash
./create.sh    # создать всё окружение (~5 мин: VPC, SG, EC2 x2, ALB)
./status.sh    # статус инстансов, target group health, стоимость
./stop.sh      # остановить инстансы + удалить ALB (экономия на простое)
./start.sh     # запустить инстансы + пересоздать ALB
./delete.sh    # удалить всё (с подтверждением)
./break.sh     # сломать одну случайную AWS-вещь (для траблшутинга)
./restore.sh   # восстановить то, что сломал break.sh
```

## Изоляция

Все скрипты работают **только с ресурсами из `.state`** — конкретные ID (`i-xxx`, `sg-xxx`, `arn:...`).
Другие ресурсы в твоём AWS-аккаунте не затрагиваются.

## Подключение

```bash
# SSH на Instance-1 или Instance-2 (IP берём из ./status.sh)
ssh -i troubleshoot-key.pem -o IdentitiesOnly=yes ec2-user@<PUBLIC_IP>

# Приложение — через ALB DNS (из ./status.sh)
http://<ALB_DNS>
```

> `-o IdentitiesOnly=yes` нужен если в SSH-агенте много ключей —
> без него SSH перебирает все ключи и получает "Too many authentication failures".

## Сценарии поломок (break.sh)

Подробное описание каждого сценария с диаграммами, симптомами и диагностикой → **[SCENARIOS.md](SCENARIOS.md)**

`./break.sh` случайно выбирает один из 7 сценариев. Диагностируй, потом `./restore.sh`.

| # | Сценарий | Что сломано | Симптом |
|---|----------|-------------|---------|
| 1 | `alb_sg_block_http` | Убран порт 80 из ALB SG | Браузер зависает, curl timeout |
| 2 | `ec2_sg_block_alb` | Убрано правило ALB→EC2 в EC2 SG | ALB отвечает 502 Bad Gateway |
| 3 | `tg_deregister_all` | Оба инстанса выброшены из Target Group | ALB отвечает 503 Service Unavailable |
| 4 | `rtb_drop_default_route` | Удалён маршрут 0.0.0.0/0→IGW | Всё недоступно: ни SSH, ни HTTP |
| 5 | `igw_detach` | IGW отцеплен от VPC | Всё недоступно (другая причина, чем #4) |
| 6 | `nacl_deny_http` | DENY port 80 в Network ACL | SG открыт, но трафик блокируется на уровне выше |
| 7 | `stop_instance_1` | Instance-1 остановлен | ALB работает, но через один инстанс |

## Полезные команды на инстансе

```bash
# статус сервисов
sudo systemctl status taskapp nginx

# логи в реальном времени
sudo journalctl -u taskapp -f
sudo journalctl -u nginx -f

# лог первичного запуска (userdata)
sudo cat /var/log/userdata.log

# база данных
sudo -u appuser sqlite3 /var/app/tasks.db "SELECT * FROM tasks;"
```

## Полезные AWS CLI команды для диагностики

```bash
# Security Group правила
aws ec2 describe-security-groups --group-ids <SG_ID>

# Target Group здоровье
aws elbv2 describe-target-health --target-group-arn <TG_ARN>

# Маршруты в Route Table
aws ec2 describe-route-tables --route-table-ids <RTB_ID>

# Состояние IGW
aws ec2 describe-internet-gateways --internet-gateway-ids <IGW_ID>

# Network ACL правила
aws ec2 describe-network-acls --filters Name=vpc-id,Values=<VPC_ID>

# Состояние инстансов
aws ec2 describe-instances --instance-ids <ID1> <ID2>
```
