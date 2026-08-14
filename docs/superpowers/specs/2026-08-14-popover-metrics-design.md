# Панель метрик попапа: «Диск VM», живые «Давление»/«Скорость свопа», порог «Свопа», удаление «Компрессора»

Дата: 2026-08-14. Статус: дизайн утверждён устно, реализация в этой же сессии.

## Зачем

После серии сборок grount диск `/var/lib/docker` внутри colima VM заполнился до 100%,
buildkit запускал GC посреди сборки, и сборка деградировала в разы. Панель метрик DevDeck
этого не показывала: метрики диска VM нет вообще, а «Давление» и «Скорость свопа» пусты вне
активной сборки. Дополнительно «Своп» даёт ложную тревогу (оранжевый при любом >0), а
«Компрессор» дублирует «Память»+«Давление».

## Изменение 1 — ячейка «Диск VM»

Новый файл `DevDeck/Diagnostics/VMDisk.swift` по образцу `ClusterHealth.swift`:

- `struct VMDiskInfo: Equatable { usedBytes: UInt64; totalBytes: UInt64 }`,
  `fraction`, `format()` → `"40 / 98 GB · 43%"` (стиль `VMMemoryInfo.format()`).
- Чистая функция `parseDF(_ output: String) -> VMDiskInfo?` — парсит `df -Pk` (POSIX-формат,
  1024-байтные блоки; вторая строка, колонки 2 (total) и 3 (used), × 1024). Мусор/пусто → nil.
- `protocol VMDiskProbing: Sendable { func sample() -> VMDiskInfo? }`.
- `LiveVMDiskProbe`: `colima ssh -- df -Pk /var/lib/docker` через `ProcessTree.run`
  с фолбэком `/opt/homebrew/bin/colima` → `/usr/bin/env colima` (как в `LiveClusterHealthProbe`).
  colima не запущена / ошибка → nil → пустая ячейка.

Подключение в `ProcessManager`:

- Инжект `diskProbe: any VMDiskProbing = LiveVMDiskProbe()` в init.
- `private(set) var cachedVMDisk: VMDiskInfo?` + `func refreshVMDisk() async`
  по образцу `refreshClusterHealth()` (off-main, `Task.detached(priority: .utility)`).
  Гейт — существующий `isVMMonitoringEnabled()`; выключено → кеш чистится в nil.
- Каденция: из 15-секундного `.task`-цикла попапа (рядом с `refreshClusterHealth()`).
  Во время сборки — дополнительно из сэмплера раз в ~15 тиков (счётчик), чтобы
  уведомление работало и при закрытом попапе.

Ячейка: на место «Компрессора» (сетка остаётся 2×4), лейбл `L10n.diskVM`
(«VM disk» / «Диск VM»), цвет — существующий `pressureColor(fraction)`.

Уведомление: тем же механизмом `warnedThresholds` (одно за запуск), при `fraction ≥ 0.90`
во время сборки: «Диск colima VM почти заполнен: N% (X / Y ГБ). Сборки замедлятся —
рекомендуется docker prune». Порог — тот же 0.90, что `memoryWarnThreshold`.
Текст уведомления и лейбл — через `L10n` (EN/RU), как остальные строки.

## Изменение 2 — живые «Давление» и «Скорость свопа» вне сборок

`ProcessManager.refreshHostSample() async`:

- Гейты: `isHostMonitoringEnabled()`; no-op при `!active.isEmpty` (сэмплер уже обновляет
  раз в секунду — не гоняем `updateSwapRate` из двух источников).
- Снимает `hostProbe.sample(buildPID: nil)` off-main, кладёт в `cachedHostSample`,
  прогоняет через существующий `updateSwapRate(cur:now:)` — математика скорости не меняется.
- Вызов из существующего 2-секундного `.task`-цикла попапа, рядом с `refreshVMSample()`.
- Очистка кешей при остановке сэмплера (ProcessManager.swift:1071–1076) не меняется:
  открытый попап заново наполнит их за ≤2 с.

## Изменение 3 — порог для «Свопа»

Чистая функция в `SystemMemory`: уровень тревоги по доле свопа от физической RAM
(машинно-независимо): `< 0.10` → обычный серый, `0.10–0.25` → оранжевый, `> 0.25` → красный.
Ячейка при нуле остаётся пустой, как сейчас.

## Изменение 4 — удаление «Компрессора»

Убираются ячейка в `PopoverView` и `L10n.compressor` (других использований нет).
`compressorPages` / `compressorFraction` в `HostMetricsSample` остаются — используются
в логе статистики запуска (`ProcessManager.swift:1015`) и покрыты тестами.

## Настройки

Новых тумблеров нет: диск — под `isVMMonitoringEnabled()`, живой хост-сэмпл — под
`isHostMonitoringEnabled()`.

## Тестирование

По конвенциям проекта: фейковые пробы, без реальных процессов.

- `VMDiskTests`: `parseDF` на реальном выводе `df -Pk`; мусор/пустая строка/нулевой total → nil;
  `format()`; `fraction`.
- `ProcessManagerTests`: фейковый `VMDiskProbing` → `refreshVMDisk()` наполняет кеш и чистит
  при выключенном мониторинге; уведомление о диске ≥0.90 ровно один раз за запуск (фейковый
  `Notifier`); `refreshHostSample()` наполняет `cachedHostSample`, два вызова дают скорость
  свопа, no-op при активной сборке.
- Тест чистой функции порога свопа (границы 0.10 / 0.25).

Прогон: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test`.
