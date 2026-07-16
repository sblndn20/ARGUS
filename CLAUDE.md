# ARGUS — контекст проекта

Читается автоматически в начале каждой сессии. Здесь то, что дорого выяснять заново.

## Что это

Приложение на Lua для мода **OpenComputers** под сборку **GregTech: New Horizons 2.8.3**.
Мониторит энергобуферы, выводит на монитор компьютера и в AR-очки одновременно.

Производная работа от [NIDAS](https://github.com/S4mpsa/NIDAS) (**GPL-3.0**, поэтому ARGUS
тоже GPL-3.0 — см. [NOTICE.md](NOTICE.md)). Взят графический слой, всё остальное вырезано,
слой данных и панель энергии переписаны заново.

Название планируется расширять функционалом за пределы энергии — отсюда ARGUS
(«стоглазый страж»), а не прежнее EMON (Energy MONitor).

- Репозиторий: `github.com/sblndn20/ARGUS` (переименован из `monitoring-app`)
- Установка: `/home/ARGUS`, автозапуск через `/home/.shrc`
- Коммиты **только от имени владельца**, без `Co-Authored-By`

## Целевые версии — проверять по ним, не по master

GTNH `master` в GitHub — это уже 2.9-dev, и там **другие форматы**. Всё сверялось по тегам
из [манифеста DreamAssemblerXXL 2.8.3](https://github.com/GTNewHorizons/DreamAssemblerXXL/blob/master/releases/manifests/2.8.3.json):

| Мод | Версия в 2.8.3 |
|---|---|
| GT5-Unofficial | `5.09.51.482` |
| OpenComputers | `1.11.20-GTNH` |
| Computronics | `1.9.3-GTNH` |
| OCGlasses | `1.6.1-GTNH` |

## Грабли OpenComputers — каждая стоила отладки

**Методы прокси — вызываемые ТАБЛИЦЫ, а не функции.** `machine.lua:1366`:
`proxy[method] = setmetatable({address=..., name=...}, componentCallback)`. Поэтому
`type(proxy.getSensorInformation) == "function"` — **false**, и такая проверка отвергает
каждый метод каждого компонента (симптом: здоровый LSC выглядит пустым, буферы не
находятся). Использовать `core.util.callable`. Фикстуры тестов обязаны воспроизводить эту
форму — на плоских функциях баг проходит мимо тестов.

**`package.loaded` живёт всю сессию до перезагрузки компьютера.** Весь компьютер — один
Lua-стейт, OpenOS держит одну таблицу `package` (`boot/01_process.lua`), песочницы на
программу нет. `lib/package.lua:76` отдаёт модуль из памяти. Скрипты (`init.lua`,
`tools/sensordump.lua`) читаются с диска каждый запуск, а `require`-модули — нет; отсюда
смесь нового и старого кода после обновления. Обе точки входа чистят свои неймспейсы из
`package.loaded` — при добавлении новых неймспейсов **обновить списки там**.

**`filesystem.copy` умеет только файлы.** Реализован как `filesystem.open(from, "rb")` —
на каталоге молча возвращает `false`. Копировать `settings/` как каталог = потерять
настройки без единой ошибки.

**Числа Lua — double.** Выше 2^53 (~9·10¹⁵) точное значение не представимо. Заряд хранится
и числом (математика), и **точной десятичной строкой** из сенсора (отображение).

**`gpu.set` двигает курсор по символам, `#` считает байты.** Любой не-ASCII (`●`, `…`, `▏`)
ломает вёрстку. Использовать `lib.utils.text` (`len`/`sub`/`fit`/`upper`/`char`).

**`component.list()` ключуется полным UUID.** Индексировать её сокращённым адресом — всегда
`nil` (в NIDAS из-за этого не работал Battery Buffer). Резолвить через `component.get`.

**Буферы GPU требуют T3.** `allocateBuffer` проверять через `pcall`, а не `type(...)`
(см. первую граблю). Без T3 — прямая отрисовка, мерцает.

**Lua 5.2-совместимость**: без побитовых операторов (`>>`, `&`).

## Грабли GregTech / GTNH

**LSC врёт в `getEUStored()` выше 2^63.** `MTELapotronicSuperCapacitor.getEUVar()` делает
`stored.longValue()` на BigInteger — это **обрезает**, а не ограничивает. Починено только в
2.9 отдельным компонентом `LSC`, которого в 2.8.3 нет. Поэтому заряд и ёмкость LSC берутся
из **строк сенсора** (они рендерятся из BigInteger), а скорости — из структурных геттеров.

**Строки сенсора парсить по ЛЕЙБЛАМ, не по индексам.** NIDAS брал `[2]`, `[5]`, `[23]` —
аддон вставляет строку, и вместо ошибки получаются молча неверные числа.

**Формат сенсора LSC в 2.8.3** — 24 строки, локализованные, с §-кодами. Значения дублируются:
с разделителями и в научной нотации (`1,234` и `1.234E9`) — научный близнец нельзя парсить
как точные цифры. Средние несут хвост `(last 5 minutes)` — эти цифры испортят наивный
разбор. GTNH считает средние за 5 мин / 1 час сам — брать их, а не пересчитывать.

**Wireless EU в 2.8.3 читается только из строк 23/24 сенсора LSC** — API нет.

**Компонент `gt_machine` даёт Computronics**, а не GregTech и не OC. `getSensorInformation()`
== `getInfoData()`. На один прокси слиты драйверы Computronics + OC, поэтому доступны и
`getEUStored()`, и `getStoredEUString()`.

**Adapter обязателен** и должен касаться блока-**контроллера** мультиблока. MFU в адаптере —
до 16 блоков.

## Грабли OCGlasses

Мод — **OCGlasses `1.6.1-GTNH`** ([исходники](https://github.com/GTNewHorizons/OCGlasses)),
не OpenGlasses2 и не OpenPeripheral.

- **Интерактивных виджетов нет** — только примитивы рисования. Кнопки рисуются вручную,
  попадание проверяется своим хит-тестом.
- Сигналы: `glasses_on(user, w, h)`, `glasses_off(user)`, `hud_click(user, x, y, button)`,
  `hud_keyboard(user, char, key)`, `block_interact`, `overlay_opened/closed`.
- **Ввод существует только при открытом оверлее Free Cursor**, а обе клавиши
  (`Free Cursor (Hold)` / `(Toggle)`) **по умолчанию НЕ назначены** — `new KeyBinding(..., 0, ...)`.
  Без бинда пользователю кажется, что приложение сломано. Раздел в игре подписан
  **«OC Glasses»** (`openGlasses` — только lang-ключ).
- `hud_click` присылает координаты в **ScaledResolution**, и `glasses_on` сообщает её же —
  поэтому размер панели берётся автоматически, иначе клики не попадут в кнопки.

## Сети: объединить без проводов НЕЛЬЗЯ

Видимость компонента существует только внутри одного объекта `Network`; сети соединяются
лишь через `Node.connect()` (физический контакт). Беспроводная связь несёт **только
сообщения**.

Даже проводной **Relay сети не объединяет** — в `Hub.scala` каждая сторона это отдельный
узел в отдельной сети (`plugsInOtherNetworks`). Документация мода прямо: *"without exposing
components to computers in other networks"*. Server Rack — тот же `Hub`.

| Способ | Что передаёт | Дальность | Между мирами |
|---|---|---|---|
| MFU в Adapter | **компонент** | 16 блоков | нет |
| Wireless T1 / T2 | сообщения | 16 / 400, глушится блоками | нет |
| Linked Card (`tunnel`) | сообщения | ∞ | **да** |

**Сервер общий — базы надо разделять.** `modem.broadcast` получает любой модем в радиусе,
открывший тот же порт, а порт по умолчанию у всех один. Без ключа сервер соседа опрашивал бы
наши клиенты, а наш сервер собирал бы чужие базы. Каждое сообщение несёт `net.PROTOCOL` и
**ключ сети**; `net:accepts()` — единственная точка проверки. Ключ по умолчанию выводится из
`computer.address()` (уникален, стабилен). Это **SSID, а не пароль**: трафик открытый,
шифрования в OC нет. Настоящая изоляция — только Linked Card (точка-точка).

**Отсюда распределённый режим** (`net/`, реализован в 2.1.0): клиент на каждой базе читает
свои буферы локально и шлёт готовые числа серверу, тот подмешивает их в `monitor` через
`setRemote` — дальше они обычные view. Pull-модель + watchdog `lastSeen` → `OFFLINE`.
Оба транспорта доставляют через `modem_message`, поэтому протокол один; у `tunnel`
(Linked Card) `send` **без адреса** — пир ровно один. Сообщения тегируются `net.PROTOCOL`,
иначе чужой трафик на том же порту попадёт в парсер.

## Доставка файлов в игру

**`raw.githubusercontent.com` недоступен с сервера пользователя** — TLS-рукопожатие рвётся
(`Remote host terminated the handshake`, это `SSLSocketImpl.handleEOF()` из JDK 11+, то есть
сервер оборвал TCP после ClientHello). Это **не** конфиг OC (его фильтр дал бы
`address is not allowed`), **не** сертификаты (дали бы `PKIX path building failed`), **не**
версия Java. Работает `cdn.jsdelivr.net` — установщик пробует его первым.

**Ставить только с тега.** jsDelivr кеширует ссылку на ветку **по каждому файлу отдельно** на
часы, поэтому `@main` отдаёт файлы из разных коммитов, и все запросы при этом успешны.

**Зеркала на редиректах (githack, statically) бесполезны**: они отвечают 301 на другой хост,
а OC использует голый `HttpURLConnection`, который не следует редиректу со сменой хоста —
`wget` сохранит HTML. По той же причине `http://` вместо `https://` не обход.

**В командах обновления обязателен `&&`**: если `wget` упал, `setup` запустит **старый**
`/home/setup.lua` и молча поставит не то.

## Структура

```
init.lua              точка входа, главный цикл, чистка package.loaded
setup.lua             установщик: зеркала, миграция, проверка версии
version.lua           версия (сверяется установщиком, видна в футере)
config/               загрузка/сохранение настроек, дефолты
core/
  sensor.lua          разбор getSensorInformation() по лейблам
  sources/            адаптеры буферов (lsc, batterybuffer, ic2, energycontainer)
  monitor.lua         опрос, агрегат, виртуальные wireless-представления
  metrics.lua         скорости, средние, прогноз, шаг графика
  ring.lua            кольцевой буфер (плоские массивы — экономия RAM)
  util.lua            util.callable — см. грабли
lib/graphics/         ar.lua (очки), graphics.lua (GPU + двойная буферизация), colors.lua
lib/utils/            parser, screen, text, time
ui/                   panel, graph, widgets, app, format
ar/                   panel (карточка + хит-тест), init (менеджер, ввод, cycle)
net/                  init (транспорт modem/tunnel), server (опрос+watchdog), client (ответы)
tools/sensordump.lua  диагностика: все компоненты, геттеры, сырые строки, разбор
tests/run.lua         228 тестов, десктопный Lua
tests/preview.lua     рендер UI в текст через фейковый GPU
```

Новый тип буфера: модуль в `core/sources/` с `kind`, `label`, `componentTypes`,
`detect(proxy, lines, componentType)` → уверенность (0 = не моё), `read(proxy, lines)`;
зарегистрировать в `adapters` в `core/sources/init.lua`. Адаптеры выбираются **скорингом**:
LSC и энергохатч оба `gt_machine`, различаются только по сенсору.

## Разработка

Всё ниже рендереров — чистый Lua и тестируется вне Minecraft:

```shell
lua tests/run.lua        # 228 проверок
lua tests/preview.lua [dashboard|buffers|glasses]   # UI в текст через фейковый GPU
```

Интерпретатора в системе может не быть — ставится `winget install --id=DEVCOM.Lua`,
бинарь в `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`. Синтаксис всех файлов: `luac -p`.

**Тестировать в игре не могу** — фикстуры сенсора реконструированы по Java-исходникам.
Если цифры расходятся, просить у пользователя вывод `tools/sensordump.lua`.

### Релиз

1. `version.lua` → новая версия
2. `setup.lua`: `BRANCH` и `EXPECTED_VERSION` → та же версия
3. README: ссылки установки
4. Тесты + `luac -p`
5. Коммит (**без** `Co-Authored-By`), `git tag -a vX.Y.Z`, push ветки и тега
6. Проверить зеркало: каждый файл манифеста против содержимого тега, а не просто HTTP 200

## Ссылки

**Сборка и моды**
- [GTNH Wiki](https://wiki.gtnewhorizons.com/wiki/) · [OpenComputers в GTNH](https://wiki.gtnewhorizons.com/wiki/Open_Computers)
- [Манифест 2.8.3](https://github.com/GTNewHorizons/DreamAssemblerXXL/blob/master/releases/manifests/2.8.3.json) — точные версии модов
- [GT5-Unofficial @5.09.51.482](https://github.com/GTNewHorizons/GT5-Unofficial/tree/5.09.51.482) — `MTELapotronicSuperCapacitor.java`, `MTEBasicBatteryBuffer.java`
- [OpenComputers 1.11.20-GTNH](https://github.com/GTNewHorizons/OpenComputers) — `machine.lua` (proxy), `lib/package.lua` (require), `Hub.scala`, `WirelessNetwork.scala`
- [Computronics 1.9.3-GTNH](https://github.com/GTNewHorizons/Computronics) — драйверы `gt_machine`, `chat_box`
- [OCGlasses 1.6.1-GTNH](https://github.com/GTNewHorizons/OCGlasses) — `ClientKeyboardEvents.java`, `OpenGlassesTerminalTileEntity.java`

**API**
- [OpenComputers Docs](https://ocdoc.cil.li/) · [component API](https://ocdoc.cil.li/api:component) · [modem](https://ocdoc.cil.li/component:modem) · [Relay](https://ocdoc.cil.li/block:switch)
- [OC-GTNH-docs: gt_machine](https://github.com/guid118/OC-GTNH-docs/blob/main/docs/components/gt_machine.lua) — типизированная справка по геттерам

**Первоисточник**
- [NIDAS](https://github.com/S4mpsa/NIDAS) · [NIDAS на вики GTNH](https://wiki.gtnewhorizons.com/wiki/NIDAS)

## Открытые вопросы

- Chat Box из Computronics как альтернатива вводу с очков (радиус 40 блоков, настраивается).
- Распределённый режим не проверен в игре: тесты гоняют протокол на фейковых картах, но
  живого модема между двумя базами никто не видел.
