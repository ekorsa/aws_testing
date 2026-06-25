# AWS CLI Cheat Sheet — Support/Troubleshooting Practice

Справочник команд AWS CLI, собранный по итогам практической сессии.
Каждая команда — что делает и когда использовать.

---

## 1. Настройка CLI и идентификация

**Проверить версию AWS CLI**
```bash
aws --version
```

**Настроить credentials (интерактивно)**
```bash
aws configure
```
Спросит: Access Key ID, Secret Access Key, region, output format.

**Настроить отдельный профиль (для второго пользователя/аккаунта)**
```bash
aws configure --profile support-test
```

**Изменить одно значение без полного re-run**
```bash
aws configure set region eu-north-1
aws configure set output json
```

**Посмотреть текущие настройки**
```bash
aws configure list
```

**Список всех сохранённых профилей**
```bash
aws configure list-profiles
```

**Проверить, под кем вы сейчас авторизованы (кто я?)**
```bash
aws sts get-caller-identity
aws sts get-caller-identity --profile support-test
```

**Включить tab-completion (bash, один раз)**
```bash
echo "complete -C '$(which aws_completer)' aws" >> ~/.bashrc
source ~/.bashrc
```

---

## 2. EC2 — инстансы

**Посмотреть все инстансы: ID, статус, Security Groups, IP**
```bash
aws ec2 describe-instances \
  --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,SG:SecurityGroups,IP:PublicIpAddress}" \
  --output table
```

**То же самое, без именования полей (multiselect list вместо hash)**
```bash
aws ec2 describe-instances \
  --query "Reservations[].Instances[].[InstanceId,State.Name,SecurityGroups,PublicIpAddress]" \
  --output table
```

**Только Instance ID**
```bash
aws ec2 describe-instances --query "Reservations[].Instances[].InstanceId" --output text
```

**Остановить инстанс (не тратит compute-часы, диск остаётся)**
```bash
aws ec2 stop-instances --instance-ids i-XXXXXXXX
```

**Запустить обратно (публичный IP обычно меняется после restart, если нет Elastic IP)**
```bash
aws ec2 start-instances --instance-ids i-XXXXXXXX
```

**Полностью удалить инстанс и диск**
```bash
aws ec2 terminate-instances --instance-ids i-XXXXXXXX
```

---

## 3. Security Groups (сетевые правила)

**Посмотреть правила (inbound) конкретной Security Group**
```bash
aws ec2 describe-security-groups --group-ids sg-XXXXXXXX \
  --query "SecurityGroups[].IpPermissions[].{Protocol:IpProtocol,Port:FromPort,Source:IpRanges[0].CidrIp}" \
  --output table
```

**Закрыть порт (например SSH 22 для конкретного IP)**
```bash
aws ec2 revoke-security-group-ingress \
  --group-id sg-XXXXXXXX \
  --protocol tcp \
  --port 22 \
  --cidr 1.2.3.4/32
```

**Открыть порт обратно**
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-XXXXXXXX \
  --protocol tcp \
  --port 22 \
  --cidr 1.2.3.4/32
```

> **Важно:** Security Group — *stateful*. Если правило удалить во время уже установленного соединения, текущая сессия не разорвётся, но новая — не подключится (получите `timeout`, не `permission denied`).

---

## 4. Очистка ресурсов (чтобы не копились расходы)

Делать по порядку, после того как закончили практику:

```bash
# 1. Найти и удалить инстансы
aws ec2 describe-instances --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name}" --output table
aws ec2 terminate-instances --instance-ids i-XXXXXXXX

# 2. Проверить "осиротевшие" диски (не привязанные к инстансу)
aws ec2 describe-volumes --query "Volumes[].{ID:VolumeId,State:State,Size:Size}" --output table
aws ec2 delete-volume --volume-id vol-XXXXXXXX

# 3. Проверить snapshots
aws ec2 describe-snapshots --owner-ids self --query "Snapshots[].{ID:SnapshotId,Size:VolumeSize}" --output table
aws ec2 delete-snapshot --snapshot-id snap-XXXXXXXX

# 4. Проверить Elastic IP (платный, если не привязан к running-инстансу)
aws ec2 describe-addresses --query "Addresses[].{IP:PublicIp,InstanceId:InstanceId,AllocationId:AllocationId}" --output table
aws ec2 release-address --allocation-id eipalloc-XXXXXXXX

# 5. Проверить NAT Gateway (тарифицируется по часам + трафику, не входит в free tier)
aws ec2 describe-nat-gateways --query "NatGateways[].{ID:NatGatewayId,State:State}" --output table

# 6. Финальная проверка — все команды должны вернуть пустой вывод
```

---

## 5. Load Balancer (ALB) и Auto Scaling

**Список ALB**
```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[].{Name:LoadBalancerName,State:State.Code,ARN:LoadBalancerArn}" \
  --output table
```

**Удалить ALB**
```bash
aws elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:...
```

**Список Target Groups**
```bash
aws elbv2 describe-target-groups --query "TargetGroups[].{Name:TargetGroupName,ARN:TargetGroupArn}" --output table
```

**Проверить, включены ли access logs у ALB (пишутся в S3, НЕ в CloudWatch Logs)**
```bash
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn arn:aws:elasticloadbalancing:... \
  --query "Attributes[?Key=='access_logs.s3.enabled']"
```

**Проверить Auto Scaling Group (важно: ASG может пересоздавать инстансы автоматически)**
```bash
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[].{Name:AutoScalingGroupName,Instances:Instances}" \
  --output table
```

**Список Launch Templates**
```bash
aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output table
```

**Метрики ALB без логов (HealthyHostCount, 5XX, latency и т.д.)**
```bash
aws cloudwatch list-metrics --namespace AWS/ApplicationELB
```

---

## 6. IAM — пользователи и права доступа

Полная последовательность: создать ограниченного пользователя → дать права → протестировать Access Denied → почистить.

```bash
# 1. Создать пользователя
aws iam create-user --user-name support-test-user

# 2. Прикрепить managed policy (например, только чтение S3)
aws iam attach-user-policy \
  --user-name support-test-user \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

# 3. Создать Access Key для программного доступа
aws iam create-access-key --user-name support-test-user

# 4. Настроить отдельный профиль с этими ключами
aws configure --profile support-test

# 5. Проверить, что разрешено
aws s3 ls --profile support-test

# 6. Проверить, что НЕ разрешено (должен быть Access Denied)
aws ec2 describe-instances --profile support-test
aws s3 cp test.txt s3://bucket-name/ --profile support-test
```

**Просмотр / диагностика**
```bash
aws iam list-users
aws iam list-users --query "Users[].UserName" --output table
aws iam list-access-keys --user-name support-test-user
aws iam list-attached-user-policies --user-name support-test-user
```

**Очистка (в обратном порядке создания)**
```bash
aws iam detach-user-policy \
  --user-name support-test-user \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
aws iam delete-access-key --user-name support-test-user --access-key-id AKIAXXXXXXXX
aws iam delete-user --user-name support-test-user
```

---

## 7. CloudWatch Logs — диагностика по логам

Полная последовательность: создать group/stream → залить тестовые данные → отфильтровать.

```bash
# 1. Создать log group
aws logs create-log-group --log-group-name /support-practice/app-logs

# 2. Создать log stream внутри группы
aws logs create-log-stream \
  --log-group-name /support-practice/app-logs \
  --log-stream-name session-1

# 3. Отправить тестовые логи
aws logs put-log-events \
  --log-group-name /support-practice/app-logs \
  --log-stream-name session-1 \
  --log-events "[{\"timestamp\": $(date +%s000), \"message\": \"INFO: test message\"}]"

# 4. Посмотреть все логи в stream
aws logs filter-log-events \
  --log-group-name /support-practice/app-logs \
  --log-stream-names session-1

# 5. Найти только ошибки (substring-поиск)
aws logs filter-log-events \
  --log-group-name /support-practice/app-logs \
  --filter-pattern "ERROR"
```

**Поиск по нескольким терминам (OR)**
```bash
aws logs filter-log-events \
  --log-group-name /support-practice/app-logs \
  --filter-pattern "?ERROR ?WARN"
```

**Поиск в конкретном временном окне (нужно для разбора инцидента "что было в момент X")**
```bash
aws logs filter-log-events \
  --log-group-name /support-practice/app-logs \
  --filter-pattern "ERROR" \
  --start-time $(date -d "10 minutes ago" +%s000) \
  --end-time $(date +%s000)
```

**Посмотреть, какие log groups вообще существуют (первый шаг в незнакомой инфраструктуре)**
```bash
aws logs describe-log-groups \
  --query "logGroups[].{Name:logGroupName,Stored:storedBytes,Retention:retentionInDays}" \
  --output table
```

**Удалить log group (очистка)**
```bash
aws logs delete-log-group --log-group-name /support-practice/app-logs
```

> **Важно:** CloudWatch Logs ничего не собирает сам — данные туда нужно явно отправлять: через `amazon-cloudwatch-agent` (читает файлы логов на EC2), через managed-сервисы (Lambda/ECS пишут сами, если включено), или прямыми вызовами API из кода приложения.

---

## 8. CloudTrail — кто и что сделал (audit log)

**Найти конкретное событие по имени API-вызова**
```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RevokeSecurityGroupIngress \
  --max-results 5
```

Похоже на `history` в Linux, но:
- общий для всего аккаунта (все пользователи/роли), не только локальный
- фиксирует результат вызова (успех/AccessDenied), не просто текст команды
- показывает: кто (`userIdentity`), откуда (`sourceIPAddress`), через что (`userAgent` — CLI/Console/SDK), что изменилось (`requestParameters`/`responseElements`)
- работает "из коробки" без настройки (90 дней истории по умолчанию)

---

## 9. Cost Explorer / Billing

**Расход за период, по сервисам (без учёта free tier credit)**
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-06-01,End=2026-06-25 \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE
```

**Та же команда, но с учётом скидок/free tier credit (реальная сумма к оплате)**
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-06-01,End=2026-06-25 \
  --granularity MONTHLY \
  --metrics "NetUnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE
```

**По дням, а не за весь месяц (чтобы увидеть расход за конкретный день)**
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-06-24,End=2026-06-25 \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE
```

> **Важно:** каждый вызов `get-cost-and-usage` через API сам стоит денег (~$0.01/запрос, появляется в счёте как "AWS Cost Explorer"). Для разовой проверки дешевле смотреть через Billing Dashboard в браузере (бесплатно).

---

## 10. "Что вообще у меня работает в аккаунте" — общий аудит

**Большинство ресурсов через один запрос (не покрывает 100% типов)**
```bash
aws resourcegroupstaggingapi get-resources \
  --query "ResourceTagMappingList[].ResourceARN" \
  --output table
```

**Проверка по сервисам вручную (надёжнее, но дольше)**
```bash
aws ec2 describe-instances --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name}" --output table
aws rds describe-db-instances --query "DBInstances[].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" --output table
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName" --output table
aws lambda list-functions --query "Functions[].FunctionName" --output table
aws ecs list-clusters
aws s3 ls
```

**Проверка по ВСЕМ регионам сразу (частая причина "забытых" ресурсов — не тот регион)**
```bash
for region in $(aws ec2 describe-regions --query "Regions[].RegionName" --output text); do
  echo "=== $region ==="
  aws ec2 describe-instances --region $region \
    --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name}" --output text
done
```

---

## 11. SSH troubleshooting (не AWS-специфично, но релевантно для EC2)

**Подключение, заставляя SSH использовать только указанный ключ**
```bash
ssh -i ~/.ssh/key.pem -o IdentitiesOnly=yes ubuntu@<PUBLIC_IP>
```

**Типичные ошибки и их смысл:**
| Ошибка | Причина |
|---|---|
| `Too many authentication failures` | SSH перебрал другие ключи из agent/default до вашего → добавить `-o IdentitiesOnly=yes` |
| `Permission denied (publickey)` | Неправильный username (`ec2-user` для Amazon Linux, `ubuntu` для Ubuntu AMI) или неправильный ключ |
| `Connection timed out` | Security Group/network блокирует — пакеты не доходят вообще |
| `Connection refused` | Порт закрыт на уровне ОС (sshd не слушает) |

**Права на файл ключа (если SSH игнорирует ключ)**
```bash
chmod 400 ~/.ssh/key.pem
```

---

## 12. Категории проблем в AWS (для структурирования troubleshooting)

1. **IAM / права доступа** — Access Denied, policy/role misconfiguration → `iam`, `sts get-caller-identity`, IAM Policy Simulator
2. **Сеть** — Security Groups, NACLs, routing, DNS → `ec2 describe-security-groups`, `describe-route-tables`
3. **Стоимость/оптимизация** — забытые ресурсы, неоптимальный sizing → `ce get-cost-and-usage`, `resourcegroupstaggingapi`
4. **Состояние ресурса (lifecycle)** — ASG пересоздаёт инстансы, ALB health check помечает unhealthy → `autoscaling`, `elbv2 describe-target-health`
5. **Наблюдаемость** (инструмент, не категория проблемы) — `logs`, `cloudtrail`, `cloudwatch` — без этого невозможно диагностировать пункты 1-4
6. **Универсальные ОС/Linux-проблемы** (не AWS-специфичны, но проявляются в облаке) — SSH, SSL/TLS, конфиги приложений, файлы логов на диске

---

## 13. Best Practices (не затронуты в практике, но важны)

### Безопасность аккаунта и доступа

**Никогда не использовать root для повседневной работы.** Root — только для редких административных задач (закрытие аккаунта, смена billing). Всё остальное — через IAM-пользователей или roles.

**Включить MFA на root-аккаунте** (у вас уже было видно `mfaAuthenticated: true` в CloudTrail — это правильно).

**Не хранить Access Key в коде или конфигах, которые попадают в Git.** Для EC2/Lambda — использовать **IAM Role**, привязанную к ресурсу, вместо статичных ключей:
```bash
aws iam create-role --role-name ec2-app-role --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name ec2-app-role --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```
Roles выдают временные креды, которые сами обновляются — ничего не может "утечь навсегда", в отличие от статичного Access Key.

**Принцип наименьших привилегий (least privilege).** Не выдавать `AdministratorAccess` "на всякий случай" — давать только то, что реально нужно для задачи (как мы делали с `AmazonS3ReadOnlyAccess`).

**Ротация Access Key** — раз в 90 дней как стандартная практика:
```bash
aws iam list-access-keys --user-name some-user
aws iam update-access-key --user-name some-user --access-key-id AKIA... --status Inactive
```

**IAM Access Analyzer** — находит ресурсы, доступные извне аккаунта, которые не должны быть публичными (например, S3 bucket с публичным доступом по ошибке):
```bash
aws accessanalyzer list-findings --analyzer-arn arn:aws:access-analyzer:...
```

### Доступ к серверам без SSH-ключей

**AWS Systems Manager Session Manager** — позволяет подключаться к EC2 **без открытого порта 22 вообще**, без SSH-ключей, через IAM-права. Это современный подход, который снимает целый класс проблем (потерянные ключи, открытый SSH в интернет):
```bash
aws ssm start-session --target i-XXXXXXXX
```
Требует установки SSM Agent на инстансе (на многих AMI уже предустановлен) и IAM-роли с правом `AmazonSSMManagedInstanceCore`.

### Сетевая безопасность

**IMDSv2 (Instance Metadata Service v2)** — защищает от SSRF-атак на метаданные инстанса (через которые раньше воровали временные креды). Проверить, что включён:
```bash
aws ec2 describe-instances --query "Reservations[].Instances[].MetadataOptions"
```

**VPC Flow Logs** — логирует весь сетевой трафик на уровне ENI/subnet/VPC, отдельно от Security Group rules. Полезно для диагностики "трафик вообще не доходит" сценариев:
```bash
aws ec2 create-flow-logs --resource-type VPC --resource-ids vpc-XXXXXXXX \
  --traffic-type ALL --log-destination-type cloud-watch-logs --log-group-name /vpc/flowlogs
```

**GuardDuty** — managed threat detection, следит за аномальной активностью (например, неожиданные API-вызовы, попытки криптомайнинга на скомпрометированном инстансе):
```bash
aws guardduty list-detectors
```

### Мониторинг и алерты (помимо Budgets)

**CloudWatch Alarms** — в отличие от Budgets (которые про деньги), Alarms следят за **метриками** (CPU, память, ошибки) и могут автоматически реагировать (например, перезапустить инстанс или уведомить через SNS):
```bash
aws cloudwatch put-metric-alarm \
  --alarm-name high-cpu \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --dimensions Name=InstanceId,Value=i-XXXXXXXX \
  --alarm-actions arn:aws:sns:...
```

**AWS Trusted Advisor** — встроенный инструмент, который сам подсказывает: забытые ресурсы, security misconfigurations, возможности сэкономить, превышение service limits. Базовые проверки доступны бесплатно даже на Basic support plan:
```bash
aws support describe-trusted-advisor-checks --language en
```

**AWS Config** — следит за **drift** (когда реальная конфигурация ресурса отличается от ожидаемой) и за compliance с заданными правилами. Особенно полезно в командах, где несколько человек меняют инфраструктуру:
```bash
aws configservice describe-config-rules
```

### Лимиты и квоты

**Service Quotas** — у каждого ресурса в AWS есть лимит по умолчанию (например, "5 Elastic IP на регион", "20 EC2-инстансов одного типа"). Частая причина "почему не получается создать ресурс" в проде — упёрлись в квоту:
```bash
aws service-quotas list-service-quotas --service-code ec2
```

### Дисциплина организации ресурсов

**Тегирование (Tags)** — присваивать каждому ресурсу теги типа `Environment=test`, `Owner=jk`, `Project=support-practice`. Без этого через месяц невозможно понять, что для чего создавалось (привычка, которая бы сильно облегчила сегодняшнюю чистку аккаунта):
```bash
aws ec2 create-tags --resources i-XXXXXXXX --tags Key=Environment,Value=test
```

**AWS Organizations + multi-account стратегия** — в реальных компаниях используется *отдельный* AWS-аккаунт под каждое окружение (dev/staging/prod) или даже под каждую команду, а не один общий аккаунт со всем вперемешку. Это и про безопасность (blast radius), и про чистоту billing.

### Резюме для интервью

Если спросят "что вы знаете про AWS best practices" — связка, которая звучит уверенно:
> "Least privilege через IAM, roles вместо статичных ключей, MFA на критичных аккаунтах, Session Manager вместо открытого SSH, теги для организации ресурсов, и Budgets/Alarms для контроля и стоимости, и состояния системы."
