# ТЗ: hardening, reproducibility і multi-cloud консолідація agent-devbox

| | |
|---|---|
| Дата | 2026-09-10 |
| База | `main` на `838fc99`, реліз v0.3.4 |
| Статус | рішення затверджені, код не змінювався |
| Обсяг | 23 знахідки, 6 робочих пакетів, 2 релізи |

## 0. Принципи виконання

- Кожен робочий пакет у власній гілці, злиття в `main` лише після зеленого CI і E2E.
- Коміти без attribution trailers: без `Co-Authored-By`, без `Claude-Session`.
- Модель користувачів не змінюється: `dev` лишається з passwordless sudo. Межа безпеки переноситься на саму машину, sandbox агентів і відсутність на машині секретів, яких `dev` і так не має.
- Нова поведінка вводиться через прапорці. Дефолт змінюється лише після перевірки обох режимів в E2E.
- Документація: laconic English, README це ключова інформація і як стартувати.

## 1. Зафіксовані рішення

| # | Рішення | Суть |
|---|---|---|
| D1 | Privilege model: root лишається | `dev` зберігає `NOPASSWD:ALL` і групу `docker`. Замість UNIX-межі: секрети прибираються з user-data і з машини, команди агентів виконуються в їхніх sandbox, де sudo не працює, захисти стають стійкими до випадкових дій і видимими при навмисних |
| D2 | Строгий sandbox Claude Code за замовчуванням | `sandbox.enabled` плюс `allowUnsandboxedCommands=false`. Агент не може сам ставити системні пакети, людина може через `!` shell-режим і звичайний термінал. Вимикається прапорцем `agent_sandbox_strict=false` |
| D3 | Tailscale SSH вимикається | `tailscale up` без `--ssh`. CLI ходить звичайним SSH по ключу. Замість цього `--operator=dev` для `tailscale serve` без sudo |
| D4 | Ключ Tailscale генерується на deploy | Через OAuth-клієнт зі scope `auth_keys` і тегом `tag:devbox`: одноразовий, ephemeral, preauthorized, 15 хвилин. Секрети OAuth необов'язкові, fallback на статичний `TAILSCALE_AUTHKEY` |
| D5 | Renovate | Один інструмент для `versions.env`, трьох `package-lock.json`, `Cargo.lock` і версій actions. App встановлює власник репозиторію |
| D6 | Спільний Terraform-модуль | `terraform/modules/devbox-core` плюс reusable workflow `_deploy.yml`. Три хмари лишаються рівноправними. AWS і Azure перевіряються через `terraform test` з mock-провайдерами, поки немає акаунтів для реального E2E |
| D7 | Релізи | v0.3.5: readiness gate, quick wins, гігієна. v0.4.0: модуль, privilege model, reproducibility. Breaking змін немає, v0.4.0 сигналізує нові inputs і нову поведінку агентів |

## 2. Реєстр знахідок

Рівні: **критичний** експлуатується зараз або блокує довіру до deploy, **важливий** реальна дірка з обмеженим впливом або системний борг, **низький** якість і зручність.

| ID | Знахідка | Рівень | Доказ | Пакет |
|---|---|---|---|---|
| F-01 | Deploy завершується після `terraform apply`, не чекає `.provisioned`, `devbox-doctor` не запускається | важливий | `deploy-hetzner.yml:156-173` | WP-1 |
| F-02 | Немає E2E: жоден workflow не проходить deploy, перевірку і destroy | критичний | `.github/workflows/` | WP-1 |
| F-03 | Секрети в user-data: `TAILSCALE_AUTHKEY`, `DEVBOX_WEB_TOKEN`, слот `PROVISIONING_TOKEN`. Лишаються в `obj.pkl` cloud-init і в metadata endpoint назавжди | важливий | `cloud-init.yaml:35-41`, `bootstrap.sh:141-147` | WP-3A |
| F-04 | `dev` = root: `NOPASSWD:ALL` плюс група `docker`. Прийнято за D1, компенсується WP-3B і WP-3C | важливий | `cloud-init.yaml:17-18`, `install-base.sh:69` | WP-3 |
| F-05 | Metadata guard не персистентний, лише IPv4, лише ланцюжок `OUTPUT`. Трафік контейнерів іде через `FORWARD` з uid 0, тому будь-який контейнер читає metadata вже зараз | критичний | `bootstrap.sh:152-154` | WP-3C |
| F-06 | Tailscale SSH увімкнений: перехоплює порт 22 з tailnet, обходить sshd і `authorized_keys`, root-логін визначає ACL. Не задокументовано | важливий | `install-base.sh:77` | WP-3D |
| F-07 | Sandbox Claude Code не увімкнений, дефолтний fallback повторює невдалу команду поза sandbox | важливий | `install-agents.sh:110-122` | WP-3B |
| F-08 | `~/.codex/config.toml` не пишеться, `sandbox_mode` не зафіксований | низький | `install-agents.sh` | WP-3B |
| F-09 | Немає sudo-аудиту. `devbox-doctor` не перевіряє цілісність sudoers, sshd, guard | низький | `bootstrap.sh:112`, `smoke-test.sh` | WP-3C |
| F-10 | `docs/security.md` заявляє ізоляцію через bubblewrap, хоча її використовує лише Codex | важливий | `docs/security.md:11-12` | WP-3E |
| F-11 | Дев'ять непінованих джерел: nodesource, pnpm, Docker, Tailscale, чотири npm-пакети агентів і MCP, playwright, starship, zoxide, Antigravity. Пінуються лише yq і lazygit | критичний | `install-base.sh:62,64,68,74`, `install-agents.sh:32,55`, `install-browser.sh:23`, `install-shell.sh:43,48` | WP-4 |
| F-12 | Немає маніфесту встановлених версій, відтворити стан машини неможливо | важливий | `smoke-test.sh` | WP-4 |
| F-13 | Немає автоматичних оновлень залежностей | низький | `.github/` | WP-4 |
| F-14 | Terraform x3 і deploy-workflows x3 дубльовані: 865 рядків Terraform, `variables.tf` відрізняється на 14 рядків | важливий | `terraform/*`, `deploy-*.yml` | WP-2 |
| F-15 | AWS і Azure ніколи не проходили `apply`, CI робить лише `validate` | важливий | `lint-validate.yml` | WP-2 |
| F-16 | Web: термінал відкриває `web-<type>-<id>`, а upload і actions ідуть у статичну `main-web` | важливий | `web/server.js:158,266,360`, `web/public/index.html:295` | WP-5 |
| F-17 | Web auth: токен у URL, без cookie. Origin керує лише CORS-заголовками, POST з чужим Origin не відхиляється | важливий | `web/server.js:135-137` | WP-5 |
| F-18 | mcp/db: `db_schema_dump` обходить ліміт 64 KB, `db_list_tables` робить `count(*)` на кожну таблицю | важливий | `mcp/db/index.js:434-436`, `:214` | WP-5 |
| F-19 | Memory MCP: один файл на всі проєкти. Переживає rebuild лише на Hetzner з volume | низький | `install-agents.sh:89,134,158` | WP-5 |
| F-20 | code-intel: промах `find_definition` запускає синхронний `ctags -R` по дереву без індексу | низький | `mcp/code-intel/index.js:166-185` | WP-5 |
| F-21 | hcloud без `backups`. Deploy зі зміненим payload пересоздає сервер і home. Скасування між destroy і create лишає без сервера, README мовчить | важливий | `terraform/hetzner/main.tf:81`, `README.md` | WP-5 |
| F-22 | tmux: `refresh-client -S` на кожен `select-pane` і `select-window` | низький | `tmux.conf:55-56` | WP-5 |
| F-23 | Гігієна: v0.3.3 pre-release без пояснення, гілка `security` без унікальних комітів, stash GitHub Desktop, `lint-validate.yml` слухає неіснуючі гілки | низький | `git`, `lint-validate.yml:5` | WP-6 |

## 3. Робочі пакети

### WP-1. Readiness gate і E2E для Hetzner

Закриває F-01, F-02. Залежностей немає. Оцінка 1.5 дня. Реліз v0.3.5.

Завдання:

1. Terraform Hetzner: змінна `runner_ssh_public_key` (string, default `""`). Непорожнє значення додається другим ключем у `ssh_authorized_keys` cloud-init. Змінна `ssh_allowed_cidrs` доповнюється IP раннера `/32` на час прогону.
2. Deploy workflow, до apply: крок генерує ефемерну пару `ssh-keygen -t ed25519`, визначає публічний IP раннера, передає обидва через `TF_VAR_*`.
3. Deploy workflow, після apply: крок `Wait for provisioning` опитує по SSH `/etc/devbox/.provisioned` або `/etc/devbox/.failed` до 15 хвилин. На `.failed` друкує хвіст `/var/log/devbox-*.log` і валить job. Далі `sudo devbox-doctor` у summary.
4. Прибирання: ключ раннера видаляється з `authorized_keys` на машині, другий `terraform apply` з порожнім `runner_ssh_public_key` і без IP раннера повертає firewall. `user_data` під `ignore_changes`, тож сервер не пересоздається.
5. Якщо порт 22 закритий, Tailscale без `ssh_allowed_cidrs`, крок пропускається з попередженням у summary.
6. Новий `e2e-hetzner.yml`: `workflow_dispatch` плюс щотижневий cron. `cx22`, ім'я `agent-devbox-e2e-<run_id>`, окремий ключ state `e2e/<run_id>`, той самий readiness gate, smoke по SSH: `devbox-doctor`, `tmux -V`, версії агентів. `terraform destroy` у `always()`, `timeout-minutes: 40`.
7. `docs/hetzner.md`: семантика `.provisioned` і `.failed`, що робить gate.

Критерії приймання:

- Deploy падає, якщо provisioning впав, і показує причину в логах job.
- E2E зелений на `main`, summary містить вивід `devbox-doctor`.
- Після прогону в `authorized_keys` один ключ, у firewall лише задані CIDR.

### WP-2. Спільний Terraform-модуль і reusable workflows

Закриває F-14, F-15. Залежить від WP-1. Оцінка 2.5 дня. Реліз v0.4.0.

Завдання:

1. `terraform/modules/devbox-core`. Входи: `username`, `ssh_public_keys`, прапорці `install_*`, `tailscale_authkey`, `web_token`, `payload_url`, `payload_sha256`, `payload_ref`, `secrets_url` з WP-3A, `release_channel` з WP-4, `runner_ssh_public_key`, `agent_sandbox_strict`. Виходи: `user_data`, `replace_triggers`, `labels`. Шаблон `provisioning/cloud-init.yaml` лишається на місці, модуль рендерить його через `templatefile`.
2. `terraform/hetzner`, `aws`, `azure`: `module "core"`, у провайдері лишаються мережа, firewall, машина, volume або disk, `terraform_data` з тригерами з модуля.
3. `required_version` піднімається до `>= 1.7.0` заради `terraform test` з `mock_provider`.
4. `terraform/*/tests/plan.tftest.hcl` на кожен провайдер: `command = plan`, mock-провайдер, assert-и: `user_data` містить усі поля `devbox.env`, порт 22 закритий при Tailscale без CIDR, `payload_ref` доходить до тригера, `runner_ssh_public_key` додається лише коли непорожній.
5. CI: job `terraform test` для трьох провайдерів у `lint-validate.yml`.
6. `.github/workflows/_deploy.yml` і `_destroy.yml` з `workflow_call`: спільна логіка пакування payload, presign, apply, readiness gate, summary. Провайдерні кроки автентифікації під `if`. `deploy-<cloud>.yml` і `destroy-<cloud>.yml` стають обгортками до 30 рядків. E2E з WP-1 переходить на reusable workflow.
7. `docs/aws.md`, `docs/azure.md`: рівень перевірки, mock tests і `validate`, реальний E2E після появи акаунтів.

Критерії приймання:

- `terraform fmt`, `validate`, `test` зелені для трьох провайдерів.
- E2E Hetzner зелений після рефакторингу.
- Між `variables.tf` провайдерів лишаються тільки провайдерні змінні: тип машини, регіон, диск.

### WP-3. Privilege model: root лишається, межа переноситься

Закриває F-03, F-04, F-05, F-06, F-07, F-08, F-09, F-10. Залежить від WP-1, бажано після WP-2. Оцінка 2 дні. Реліз v0.4.0.

#### WP-3A. Секрети поза user-data

1. Workflow: якщо є `TAILSCALE_OAUTH_CLIENT_ID` і `TAILSCALE_OAUTH_CLIENT_SECRET`, отримати токен через `POST /api/v2/oauth/token` і створити ключ через `POST /api/v2/tailnet/-/keys` з `reusable=false`, `ephemeral=true`, `preauthorized=true`, `tags=["tag:devbox"]`, `expirySeconds=900`. Інакше використати `TAILSCALE_AUTHKEY`.
2. Об'єкт `secrets.env` з `TAILSCALE_AUTHKEY` і `DEVBOX_WEB_TOKEN` завантажується в той самий бакет, що і payload, presigned URL на 15 хвилин. Cloud-init отримує лише `PROVISIONING_SECRETS_URL`.
3. `bootstrap.sh` тягне `secrets.env` у `/etc/devbox/secrets.env` з правами 0600, експортує, видаляє після `tailscale up`. Workflow видаляє об'єкт у `always()` після readiness gate.
4. З `cloud-init.yaml` зникають `TAILSCALE_AUTHKEY`, `DEVBOX_WEB_TOKEN`, `PROVISIONING_TOKEN`. Змінна `git_token` видаляється, приватний репозиторій обслуговується presigned tarball.

#### WP-3B. Sandbox агентів як межа

1. `install-base.sh`: пакет `socat`. Bubblewrap і AppArmor-профіль уже є.
2. `install-agents.sh`, `~/.claude/settings.json`: `sandbox.enabled=true`, `sandbox.failIfUnavailable=true`, `allowUnsandboxedCommands=false`, `sandbox.network.allowedDomains` зі стартовим списком: `registry.npmjs.org`, `github.com`, `api.github.com`, `objects.githubusercontent.com`, `crates.io`, `static.crates.io`, `pypi.org`, `files.pythonhosted.org`, `proxy.golang.org`. Доступ до credentials не обмежується за замовчуванням, інакше `git push` і `gh` з-під агента ламаються. `sandbox.credentials` описується в docs як opt-in.
3. `~/.codex/config.toml`: `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, `[sandbox_workspace_write] writable_roots = ["/workspace"]`.
4. Прапорець `agent_sandbox_strict` у Terraform і inputs, default `true`. `false` прибирає `allowUnsandboxedCommands=false`.
5. opencode і Antigravity документуються як агенти з повним доступом.

#### WP-3C. Захисти, стійкі до випадковостей і видимі

1. `provisioning/devbox-metadata-guard.sh` і unit `devbox-metadata-guard.service`: oneshot, `Before=network.target`, drop-in для `docker.service` з `After=devbox-metadata-guard.service`. Правила: `OUTPUT` з `! --uid-owner 0` на `169.254.169.254`, ланцюжок `DOCKER-USER` з `DROP` на ту саму адресу, `ip6tables` на `fd00:ec2::254`. Docker не чистить `DOCKER-USER`, тому правила переживають його рестарт.
2. Sudoers переїжджає з `cloud-init.yaml` у `/etc/sudoers.d/90-devbox`: `dev ALL=(ALL) NOPASSWD:ALL` плюс `Defaults:dev log_input, log_output, use_pty, iolog_dir=/var/log/sudo-io`.
3. `chattr +i` на `99-devbox.conf` sshd, `90-devbox` sudoers, unit guard і `devbox-doctor`. У docs: `chattr -i` перед свідомою правкою.
4. `/etc/docker/daemon.json` з `no-new-privileges: true`. У docs: образи з setuid в entrypoint потребують `--security-opt no-new-privileges=false`.
5. `/etc/devbox/integrity.sha256` пишеться наприкінці bootstrap. `devbox-doctor` перевіряє hash sudoers, sshd drop-in і unit, наявність правил iptables, immutable-прапорці, активність guard, і друкує останні 20 команд sudo з journal.

#### WP-3D. Tailscale

1. `tailscale up` без `--ssh`, після нього `tailscale set --operator=$DEVBOX_USER`.
2. `docs/security.md`: рекомендований ACL, де `tag:devbox` є лише призначенням для `autogroup:member` на порти 22, 7681, 41641 і ніколи джерелом.

#### WP-3E. Документація

1. `docs/security.md`: threat model переписується. `dev` дорівнює root. Межа: машина disposable, sandbox Claude Code і Codex, на машині немає секретів, яких `dev` не має і так. Tailscale SSH вимкнений. Перелік того, що не захищається: opencode, Antigravity, `!` shell-режим.

Критерії приймання, усі як assert-и в E2E:

- `strings /var/lib/cloud/instance/obj.pkl` і metadata user-data не містять `tskey`, `DEVBOX_WEB_TOKEN`.
- `bwrap --unshare-user --ro-bind / / -- sudo -n true` завершується помилкою.
- `docker run --rm curlimages/curl -m 3 http://169.254.169.254/` не отримує відповіді.
- Після `reboot` правила guard на місці, `devbox-doctor` зелений.
- `tailscale debug prefs` показує `RunSSH: false`.
- Прогін з `agent_sandbox_strict=false` теж зелений.

### WP-4. Reproducibility і Renovate

Закриває F-11, F-12, F-13. Залежить від WP-2. Оцінка 1.5 дня. Реліз v0.4.0.

Завдання:

1. `provisioning/versions.env`: `NODE_MAJOR`, `PNPM_VERSION`, `DOCKER_VERSION`, `TAILSCALE_VERSION`, `CODEX_VERSION`, `CLAUDE_CODE_VERSION`, `OPENCODE_VERSION`, `AST_GREP_VERSION`, `AST_GREP_MCP_VERSION`, `MCP_MEMORY_VERSION`, `PLAYWRIGHT_MCP_VERSION`, `PLAYWRIGHT_VERSION`, `STARSHIP_VERSION`. Docker через `VERSION=` для `get.docker.com`, Tailscale через apt pin, starship через `--version`. zoxide лише з apt Ubuntu 24.04, curl-fallback видаляється. Antigravity версію не приймає, фіксується як виняток у docs.
2. Input і змінна `release_channel`: `stable` бере піни, `latest` поточну поведінку. Доходить до машини як `DEVBOX_RELEASE_CHANNEL` у `devbox.env`. Хелпер `pin NAME` в `install-*.sh`.
3. `/etc/devbox/manifest.json` наприкінці provisioning: фактичні версії node, npm, pnpm, docker, tailscale, tmux, codex, claude, opencode, agy, playwright, starship, zoxide, канал, `PAYLOAD_REF`, дата. `devbox-doctor --manifest` друкує, readiness gate додає в summary.
4. `renovate.json`: `config:recommended`, `customManagers` з regex для `versions.env` і datasource на кожен ключ, npm для `web` і `mcp/*`, cargo для `cli`, `github-actions`. Розклад щотижня, група `devbox pins` одним PR, automerge лише patch у lockfiles. Власник репозиторію встановлює Mend Renovate App.
5. E2E: щотижня `stable`, щомісяця `latest`.

Критерії приймання:

- Два provisioning на одному коміті з `stable` дають однаковий `manifest.json`.
- E2E на `stable` і `latest` зелені.
- Renovate відкриває PR на штучно знижений пін.

### WP-5. Quick wins

Закриває F-16, F-17, F-18, F-19, F-20, F-21, F-22. Залежностей немає, паралельно з будь-яким пакетом. Оцінка 1.5 дня разом. Реліз v0.3.5.

1. Web: rebase і merge `wip/web-sessions-db-guardrails`, тести на cookie-парсер і порядок auth, явна відмова 403 для POST на `/upload` і `/action` з чужим Origin, README web.
2. mcp/db: `db_schema_dump` через той самий ліміт 64 KB з підказкою звузити до `db_describe_table`. `db_list_tables` з `include_counts=false` за замовчуванням, `true` рахує точно. Тести на обидва.
3. Memory: обгортка `~/.devbox/bin/devbox-memory`, яка ставить `MEMORY_FILE_PATH=<git-root>/.devbox/memory.jsonl`, поза репозиторієм `~/.devbox/memory.jsonl`. `.devbox/` у глобальний `core.excludesfile`. `claude mcp add memory -- devbox-memory`.
4. Hetzner: змінна `backups` з default `true` для `hcloud_server`. README: deploy зі зміненим payload пересоздає сервер, home не персистентний без volume, скасування deploy між destroy і create лишає без сервера.
5. code-intel: індекс `~/.cache/devbox/code-intel/<sha1 шляху>.json` з `ctags -R --output-format=json`. Ключ свіжості: `git rev-parse HEAD` плюс кількість рядків `git status --porcelain`. Промах відповідає результатом `rg` і запускає перебудову у фоні, `get_outline` оновлює записи свого файлу. Тести на fixture-репозиторії.
6. tmux: заміряти вплив хуків `refresh-client -S` при швидкому колесі в copy-mode. Якщо помітний, лишити лише `after-select-window`. Інакше закрити без змін.

Критерії приймання:

- Web: файл, надісланий з телефона, з'являється в тій панелі, яку видно у браузері.
- mcp/db: dump бази з 200 таблиць повертає не більше 64 KB.
- Два проєкти на одній машині мають різні memory-файли.
- `find_definition` на теплому індексі відповідає без запуску `ctags -R`.

### WP-6. Гігієна

Закриває F-23. Залежностей немає. Оцінка 30 хвилин. Реліз v0.3.5.

1. Реліз v0.3.3: у нотатках "superseded by v0.3.4", позначка pre-release лишається.
2. Гілка `security` видаляється локально і на origin: унікальних комітів немає, цінна робота в `wip/web-sessions-db-guardrails`.
3. Stash GitHub Desktop: власник звіряє `git stash show -p` з `wip/web-sessions-db-guardrails` і дропає.
4. `lint-validate.yml`: `branches: [main]`.

## 4. Послідовність і релізи

| Крок | Пакет | Залежить від | Оцінка | Реліз |
|---|---|---|---|---|
| 1 | WP-6 гігієна | немає | 0.5 год | v0.3.5 |
| 2 | WP-1 readiness gate, E2E | немає | 1.5 дн | v0.3.5 |
| 3 | WP-5 quick wins | немає, паралельно з WP-1 | 1.5 дн | v0.3.5 |
| 4 | WP-2 модуль, reusable workflows | WP-1 | 2.5 дн | v0.4.0 |
| 5 | WP-3 privilege model | WP-1, WP-2 | 2 дн | v0.4.0 |
| 6 | WP-4 reproducibility, Renovate | WP-2 | 1.5 дн | v0.4.0 |

Разом близько 9.5 днів. WP-3 і WP-4 не залежать одне від одного, можуть іти паралельно після WP-2.

Обов'язки власника репозиторію по ходу: встановити Mend Renovate App, створити OAuth-клієнт Tailscale зі scope `auth_keys` і тегом `tag:devbox` і додати два секрети, за бажанням додати акаунти AWS чи Azure для реального E2E.

## 5. Definition of Done програми

- Кожен `deploy-*.yml` завершується лише після `devbox-doctor` на живій машині.
- E2E Hetzner зелений щотижня на `stable` і щомісяця на `latest`.
- `terraform test` покриває три провайдери, між ними лише провайдерні змінні.
- На машині після provisioning немає жодного секрету, який доступний root і не доступний `dev`.
- Команди Claude Code і Codex за замовчуванням не можуть виконати `sudo`, людина може.
- Metadata недоступний з-під `dev` і з контейнерів, правила переживають reboot.
- `manifest.json` на машині збігається з `versions.env` у `stable`.
- `docs/security.md` описує реальну модель, README лишається коротким.
- Жоден коміт не містить attribution trailers.

## 6. Ризики і відкриті питання

- Неефективність setuid всередині bubblewrap випливає з user namespaces, документація Claude Code цього не стверджує прямо. Assert у E2E з WP-3 обов'язковий до зміни дефолту.
- Строгий sandbox змінює щоденний досвід: домени поза стартовим списком потребують підтвердження, `sudo` з-під агента падає. Прапорець `agent_sandbox_strict=false` є шляхом назад.
- `obj.pkl` не видаляється, cloud-init на наступному boot перечитує datasource і може повторити per-instance модулі. Замість цього секрети прибираються з user-data повністю.
- Реальний E2E для AWS і Azure потребує акаунтів. Без них стеля для двох хмар це mock tests і `validate`, і це буде написано в docs.
- Задеплоєна машина 178.105.227.8 після v0.4.0 потребує пересоздання: home втрачається, логіни агентів доведеться повторити. Volume `/workspace` лишається.
- Renovate дає потік PR. Групування в один тижневий PR і без automerge для `versions.env` тримають шум під контролем.
