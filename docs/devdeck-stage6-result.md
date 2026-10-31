> Актуальный итог на 31 октября 2026: PASS — 34 targeted + 929 full-suite tests, focused live acceptance пройден. См. финальный раздел в конце; прежние UNVERIFIED ниже исторические.

# Этап 6 — мониторинг Mac, контейнеров и питания

## Checkpoint 1: контракт и исследование (до кода)

Основа: df1dfd3a962d4e81d1f48b94174c633a2c7c9b69 + 43 разрешённых файла этапов 3–5; SHA256 проверены, `.stage6-artifacts/baseline-manifest.json`, копии baseline отдельно. Основной checkout не изменялся.

Единый контракт: MON-01 в devdeck-modules-spec.md, этап 6 implementation-plan. Согласованный интерфейс сохраняется: панель 380 pt, Mac / Контейнеры / Питание, подробности в полном окне. Нового плана и новых фазовых согласований нет.

Найдено: MonitoringMetricsView читает SystemMemory/getloadavg из TimelineView; DeckMonitoringModel разделяет цикл между popover и MonitoringPage, но не имеет timestamp/history/stop. ProcessManager.refreshHostSample уступает run sampler; VM/disk/cluster не проверяют конфигурацию после await. EnergyModel имеет независимый background lifecycle, не должен потерять учёт при закрытии панели; после energy snapshot также нужна проверка enable/cancel. Settings хранит отдельные host/VM/battery toggles.

Native read-only проверка на Mac17,9, 15 CPU: HOST_CPU_LOAD_INFO KERN_SUCCESS, counters [81442693,29543078,413183596,0]; root statvfs: 242824745 blocks ×4096 B, free 6345253 blocks; kern.boottime 1792306121. Батарея есть, pmset: 100%, AC, не заряжается. AppleSmartBattery: CycleCount 96, DesignCapacity 6249, AppleRawMaxCapacity 6314, NominalChargeCapacity 6466, Voltage 13214 mV, InstantAmperage 0 mA; AdapterDetails Watts 65 — номинал адаптера, НЕ потребление Mac. Несовпадающие capacity источники не превращать в медицински точное «здоровье %». IOAccelerator содержит Device/Renderer/Tiler Utilization %, но это driver-specific источник, не универсальный публичный контракт. Температуры пока UNVERIFIED; thermalState — уровень thermal pressure, не °C.

Предлагаемая реализация в согласованном объёме: injectable kernel/power probe вне MainActor, CPU delta с первым/сброшенным/недоступным sample, root disk/uptime, общий timestamped snapshot, ограниченная история Charts. Load average отдельной строкой. Конфигурация enable/interval/history с defaults, существующие gates обязательны. Один sampler, поколения для отмены/смены движка/сна; последний snapshot при остановке сохраняется с временем. ProcessManager/Energy сохраняют владельцев своих run/background samplers, UI не запускает probes.

Открытый дополнительный выбор: GPU/физические температуры. В базовой части показывать unavailable с причиной; зависимости/helper не внедряются. Перед расширением сравнить публичные native возможности с готовыми библиотеками/helper и передать выбор пользователю. Наличие driver-specific ключа само по себе не доказывает переносимость или физический смысл.

Порядок работ: красные regression tests → sampler/probes/config → общий UI и графики → целевые проверки/checkpoint 2 → исправления → один полный suite и изолированный UI/checkpoint 3. Сохранить отдельный stage6-owned patch относительно baseline, идентичность сборки и PASS/FAIL/UNVERIFIED. Commit/push/merge/установки запрещены.

## Проверки

- PASS: перенос разрешённых исходников и SHA256 (43 файла).
- PASS: read-only native CPU/disk/boot/battery capability probe.
- UNVERIFIED: реализация, тесты, UI — ещё не выполнены.

## Независимая базовая часть после записи checkpoint 1

Добавлены MonitoringSettings и JSON decoding в Settings: defaults enabled=true, interval=2 s, history=true; effective interval 1…60 s, предел истории 180 samples. Существующие host/battery/VM gates не менялись. UI/sampler ещё не подключены.

RED: MonitoringSettingsTests.testMonitoringOptionsSurviveConfigRoundTripIndependentlyOfHostToggle — ожидаемый XCTUnwrap failure (monitoring отсутствует после round-trip), `.stage6-artifacts/red-settings.log`.
GREEN: тот же тест прошёл, `.stage6-artifacts/green-settings.log`; ConfigCodec/defaults дополнительные проверки в `.stage6-artifacts/settings-targeted.log`.

Build identity: Xcode project DevDeck, scheme DevDeck, macOS arm64, CODE_SIGNING_ALLOWED=NO, derived data `.stage6-build`; исходный HEAD указан выше. Полный suite и UI не запускались; acceptance .app не создавалась, stage5 .acceptance-app и установленное приложение не тронуты. Это checkpoint 1, не готовый этап 6.


## Checkpoint 2 — первый полный срез, 27 октября 2026

Консолидация завершена: текущая ветка stage6-monitoring в прежней папке devdeck-clipboard-stage5-ui-acceptance. Только main и этот worktree; старый source удалён родителем через public Guild API. Подробности и inventories: docs/devdeck-consolidation-2026-10-27.md. Архив .stage6-build не использовался для новых проверок.

Реализованы общий timestamped snapshot, CPU busy из kernel counter deltas отдельно от load average, optional memory/pressure/swap, root disk, uptime, батарея/циклы/состояние/номинал адаптера/мощность батареи. Неполученные значения отображаются как unavailable, GPU и физическая температура имеют явную причину отсутствия. Старые SystemMemory.current и HostMetrics fallback сохранены для прежних callers; новый UI использует availability. Номинал адаптера не назван потреблением Mac.

Один DeckMonitoringModel обслуживает readers, сохраняет последнее значение при остановке, ограничивает историю 180 samples и отменяет публикацию старых поколений. Закрытие последнего reader, reopen, master, gates, engine и sleep обрабатываются без запуска перекрывающего UI sampler. Container probes ограничены периодом 15 секунд; изменение interval/reopen не обходит deadline. Нативные Charts и настройки interval/history/master подключены в полном окне, snapshot-only компактный UI — в панели 380 pt.

ProcessManager повторно проверяет gates/revision/cancellation после await для VM, minikube, disk, host и cluster. UI master не выключает run sampler/alerts. EnergyModel проверяет enabled после каждого из трёх energy snapshot await; отмена UI не очищает независимый background tally. Shared callers проверены поиском и целевыми тестами ProcessManager, EnergyModel, DeckMonitoringModel, CleanupView.

### Проверки текущего среза

- PASS: 52 целевых теста, 0 failures, xcodebuild exit 0, TEST SUCCEEDED. Лог .stage6-current-artifacts/complete-slice-targeted.log; время 19:40–19:42, 101.458 s. Классы: ClusterHealthTests, DeckMonitoringModelTests, EnergyModelTests, HostMetricsTests, MonitoringEnergyRaceTests, MonitoringRefreshRaceTests, MonitoringSampleTests, MonitoringSettingsTests, MonitoringSnapshotTests, PanelLayoutTests, ProcessManagerDiskTests, ProcessManagerHostMemoryTests, ProcessManagerHostRefreshTests, ProcessManagerMinikubeRefreshTests, ProcessManagerVMSamplerTests.
- PASS: CPU first/reset/no-delta/missing; bounded history; generations, multiple readers, cancellation/reopen, master/sleep/engine change; disable/cancel/revision во всех пяти shared refresh; три enabled-after-await ветки energy и отмена UI без потери tally. Новые unit regressions используют фейки.
- PASS: существующий PanelLayoutTests, включая 380 pt, EN/RU, light/dark и минимальный размер; тест занял 98.337 s и завершился штатно. Это hosting/layout проверка, не финальная live acceptance. Снимки приложены в xcresult, также сохранены в .stage6-current-artifacts/layout-screenshots.
- PASS: git diff --check.
- Исторические RED подтверждены: late disk publish/продолжение heavy probe после last-reader cancellation (.stage6-current-artifacts/initial-targeted.log); потеря energy tally при отмене UI (.stage6-current-artifacts/energy-cancel-red.log). Эти регрессии исправлены и входят в последний GREEN. Промежуточные compile failures (повторное имя переменной и ошибочная метка test initializer) исправлены до GREEN; логи сохранены.
- UNVERIFIED: полный suite текущего финального кода, живое сравнение CPU/disk/uptime/battery с системой, live off/interval/reopen, окончательная UI-приёмка новой stage6 app. Это checkpoint 3 после родительской проверки/corrections. Docker/Colima пользователя не переключались.

Build: DEVELOPER_DIR=/Applications/Xcode.app, DevDeck.xcodeproj, scheme DevDeck, macOS arm64, CODE_SIGNING_ALLOWED=NO, новый derived path .stage6-current-build. Xcresult: .stage6-current-build/Logs/Test/Test-DevDeck-2026.10.27_19-40-30-+0300.xcresult. Точные SHA256 executable/debug dylib и текущих owned files: .stage6-current-artifacts/checkpoint2-identity.json и stage6-owned-files.json. Актуальный patch относительно baseline этапов 3–5: .stage6-current-artifacts/stage6-owned.patch (не общий git diff с изменениями этапов 3–5).

Ограничения для родительской проверки: график пока сохраняет старые VM points при смене engine, хотя snapshot инвалидируется; пустая серия конкретной секции при непустой общей истории не показывает waiting overlay. Uptime использует краткие d/h/m, signed battery power — W в обеих локалях. Эти детали требуют оценки в финальной UI-приёмке, PASS по ней не заявлен.

Исходники на checkpoint 2 заморожены для parent inspect. Самостоятельное ревью не запускалось. Коммитов/stage/push/merge нет, main и стабильная stage5 .acceptance-app не изменялись. Новая stage6 app для ручной проверки ещё не запущена.


## Checkpoint 2, исправления root перед code review — 27 октября 2026, 19:53

Этот раздел заменяет перечисленные выше ограничения checkpoint 2; прежние записи и логи оставлены историческими.

1. **PASS — uptime с загрузки, включая сон.** MonitoringUptime использует существующий LiveBootTime/kern.boottime и текущую Date. Ошибка источника (.distantPast), нулевая/отрицательная, будущая или нечисловая дата дают nil. ProcessInfo.systemUptime удалён из monitoring. BootTimeProviding/LiveBootTime и контракт restore tabs не изменены. Регрессия с fake source/clock проверяет elapsed time через условный sleep и некорректные даты. Первичный API, на различие семантики которого указал root: https://developer.apple.com/documentation/foundation/processinfo/systemuptime. Сравнение live UI с /usr/bin/uptime и kern.boottime остаётся UNVERIFIED до checkpoint 3.
2. **PASS — VM history.** Смена engine или running state очищает только vmMemory во всех точках; snapshot containers инвалидируется. Mac и battery series сохраняются. Регрессии colima → Docker Desktop и остановка Colima проверяют сохранность независимых значений и отсутствие прежней VM-серии.
3. **PASS — пустая серия выбранной секции.** Наличие данных определяется отдельно для Mac, containers, energy. При непустой Mac history и пустых VM/battery отображается локализованное ожидание; фиктивных нулей нет. Native NSHostingView fixtures сохранены в .stage6-current-artifacts/empty-history-screenshots/{containers,energy}-{en,ru}.png и xcresult attachments. Визуально проверены containers-ru и energy-en: подпись видна, фон подписи закрывает проходящую под ней линию сетки. Это fixture evidence, не live acceptance.
4. **PASS — hostMemoryMonitoring.** Новый MonitoringKernelProbing.sample(includeMemory:) всегда собирает базовые CPU/load/disk/uptime при включённом master и readers. Memory/host closures вообще не вызываются при false. Отдельные native-probe и production-sampler regressions проверяют gate и продолжение Mac snapshot. Переключатель сохраняет смысл memory/build alerts; новая подпись явно сообщает, что выключен сбор памяти, а не весь Mac. Master-off продолжает сохранять последний timestamped snapshot.
5. **PASS — локализация.** Uptime d/h/m → д/ч/мин через L10n, signed battery watts использует существующий L10n.watts, новые disk/swap-rate единицы GiB/ГиБ и MiB/s/МиБ/с локализованы. Принятые размеры панели не менялись.

Проверки: финальный targeted прогон **18 tests, 0 failures, xcodebuild exit 0, TEST SUCCEEDED**, .stage6-current-artifacts/root-corrections-final2.log. Классы: MonitoringCorrectionsTests (7), MonitoringSampleTests (2), MonitoringSnapshotTests (3), DeckMonitoringModelTests (1), MonitoringRefreshRaceTests (3), MonitoringSettingsTests (2). Полный suite не запускался. Xcresult: .stage6-current-build/Logs/Test/Test-DevDeck-2026.10.27_19-52-58-+0300.xcresult. git diff --check PASS; новый Sendable warning устранён.

RED: .stage6-current-artifacts/root-corrections-red.log — две регрессии воспроизвели исчезновение Mac snapshot при memory off и сохранение старой VM history (5 assertions). Промежуточный root-corrections-targeted.log содержит failure integration-fixture: ожидание было раньше окончания sampling и fixture оставляла default VM probes enabled (read-only); исправлены fixture gates и ожидание publication. В финальном прогоне источники fake, реальные CLI/kernel/network/clipboard probes не используются тестами. Последующий root-corrections-final.log — 17 PASS; затем добавлен VM restart test и уточнена подложка empty overlay, окончательный final2 — 18 PASS.

Актуальные patch/list/identities перегенерированы относительно неизменённого baseline этапов 3–5; предыдущие сохранены с префиксом before-root-corrections-. Текущие файлы: .stage6-current-artifacts/stage6-owned.patch, stage6-owned-files.json, checkpoint2-identity.json. Источники снова заморожены для parent code review. Самостоятельное review не запускалось; коммитов/stage/push/merge/main writes нет.

Checkpoint 3: отдельная stage6 dev app с bundle ID **local.devdeck.monitoring-development**, отдельным derived path и новой пустой конфигурацией. Старую .acceptance-app/DevDeck.app с local.devdeck.development не перемещать/пересобирать/переподписывать/перерегистрировать. Полный suite, системные сравнения и live acceptance пока UNVERIFIED, ожидают parent review/corrections.

## Исправления A–G после независимого review 01-initial — 27 октября 2026

Работа продолжена по прямому correction task. Initial review `.revust/tasks/devdeck-stage6-monitoring/01-initial/report.md` прочитан, не изменён. Предыдущие reviewed patch/list/identity сохранены с префиксом `.stage6-current-artifacts/before-review-corrections-`. Ниже — актуальный результат, не ретроспективный PASS старой сборке.

| Finding | Причина | Исправление | Проверка |
| --- | --- | --- | --- |
| A, Major: heavy probe блокирует всё | light values публиковались только после всех await контейнерной цепочки; ProcessTree.run не имел deadline/cancellation | DeckMonitoringModel имеет независимую light публикацию и один heavy task со своим поколением/слотом; start-to-start heavy cadence ≥15 s. Только monitoring CLI используют MonitoringCommand: posix_spawn с отдельной process group, nonblocking stdout, 5 s deadline на запуск, output cap 4 MiB, SIGKILL группы и waitpid cleanup. Cancellation scope привязан к batch; UI cancel не отравляет run scope. Обычный ProcessTree.run не изменён | Slow-heavy regression доказывает light progress и отсутствие overlap; close/master/engine cancel tests подтверждают освобождение слота и fresh value; fake child+clock — deadline/cleanup без процессов. Отдельный production smoke-check shell+sleep подтверждает реальное уничтожение descendants |
| B, Major: включение gate не запускает sampler | startVMSamplerIfNeeded вызывался только по started; UI refresh уже уступал активной команде | invalidateMonitoringSamples при active command вызывает существующий startVMSamplerIfNeeded; nil-task guard исключает дублирование. Старое in-flight поколение отменяет только свой probe scope, loop продолжает с новым | testEnablingGateStartsSamplerForAlreadyActiveCommand: RED до исправления (нет disk и VM), GREEN после; существующие active run/host/minikube тесты |
| C: stale disk показан новым | active sampler сохранял прежний nonnil cachedVMDisk при nil результате | failure очищает value+date. Каждый success сохраняет cachedVMDiskDate; snapshot несёт diskMeasuredAt, строка диска показывает исходное время, независимо от даты нового контейнерного блока | testActiveRunDiskFailureClearsValueAndMeasurementDate: успешный первый run tick → failed disk → nil value/date; layout |
| D: компактная память не показывает stop | MonitoringMemoryRow читал retained bytes без состояния owner | Строка дополнена compact caption через memoryStatus: collection off/suspended или memory gate off + Last measurement с исходным timestamp; существующие L10n EN/RU | testCompactMemoryStatusKeepsTimestampWhenDisabledOrSuspended в обеих локалях; PanelLayoutTests |
| E: слабый engine generation test | nil first CPU одинаков у старого и нового результата | Исходный тест теперь запрещает старую date=1 в history и требует свежую date≥2. Heavy regression использует разные VM 111/222 и проверяет snapshot=222, отсутствие старой точки | MonitoringSnapshotTests и testSlowHeavyWorkCannotBlockLightAndOldGenerationCannotPublish |
| F: Battery condition unavailable | читался только AppleSmartBattery, public power source игнорировался | LiveMonitoringPowerProbe читает IOPSCopyPowerSourcesInfo/List/GetPowerSourceDescription, выбирает только InternalBattery, непустой BatteryHealthCondition затем BatteryHealth. Нет numeric inference; исходная строка сохраняется буквально, как разрешено заданием | fixtures: приоритет condition, health fallback, отсутствие/UPS. Read-only public-health.json на этом Mac: BatteryHealth="Check Battery", BatteryHealthCondition=""; новый selector выбирает Check Battery. Финальный Energy UI пока UNVERIFIED |
| G: Light window/dark popover | NSApp.appearance не обеспечивал нужное наследование native status popover (live FAIL подтверждён до correction) | PopoverAppearanceBinding явно связывает NSPopover.appearance с существующим AppearanceManager, наблюдает runtime changes; System сбрасывает override в nil. Нет fixed SwiftUI colorScheme | Native test переключает Light→Dark→System и проверяет appearance; layout PASS. Реальная визуальная System/Light/Dark приёмка новой app пока UNVERIFIED из-за automation permission gap |

### Ownership, границы и affected callers

MonitoringCommand применяется только в VMMemory, VMDisk, MinikubeMemory, ClusterHealth (включая их monitoring build-config reads). Per-executable timeout 5 s; fallback может занять ещё 5 s, но light loop от него не зависит. На отмене scope fallback не запускается. Cleanup убивает выделенную группу read-only CLI, включая наследующие её дочерние процессы; не применяет kill к пользовательским daemon/service PIDs. Проверенные smoke fixtures не выполняют setsid/daemonization. Утверждение об уничтожении произвольных намеренно отделившихся daemon descendants не проверено.

Существующий ProcessTree.run и его non-monitoring callers (port inspection, daemon discovery, terminal/Ghostty detection, cleanup DockerUsage, proxy curl, OOMInspector) не менялись. Поиск affected callers сохранён в corrections-live/shared-callers.txt. CleanupView и Popover продолжают читать optional cachedVMDisk; отсутствующее измерение не превращается в ноль. Active build sampler сохраняет alerts/peaks; panel master не вызывает invalidateMonitoringSamples. Memory gate остаётся отдельным от CPU/load/disk/uptime. Sleep/engine/history и legacy SystemMemory contracts сохранены. UI rendering не выполняет probes.

### Команды и результаты

- **RED:** `.stage6-current-artifacts/review-corrections-red.log`, `MonitoringReviewTests/testEnablingGateStartsSamplerForAlreadyActiveCommand`, xcodebuild exit 65, expectation timeout + nil VM, до lifecycle fix. Для A/C/D/F/G причины трассированы по коду и имеющемуся live evidence; новые regression tests выполнены с исправлениями, отдельный pre-fix RED по каждой из них не заявляется.
- **PASS:** `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS,arch=arm64' -derivedDataPath .stage6-current-build CODE_SIGNING_ALLOWED=NO` с `-only-testing:DevDeckTests/<Class>` для MonitoringReviewTests, MonitoringSnapshotTests, MonitoringCorrectionsTests, MonitoringRefreshRaceTests, MonitoringEnergyRaceTests, MonitoringSampleTests, DeckMonitoringModelTests, ProcessManagerVMSamplerTests, ProcessManagerDiskTests, ProcessManagerHostMemoryTests, ProcessManagerMinikubeRefreshTests, ClusterHealthTests, ProcessTreeTests. **55 tests, 0 failures, exit 0**. Лог review-corrections-final.log; xcresult Test-DevDeck-2026.10.27_21-07-36-+0300.xcresult.
- **PASS:** отдельно тот же command с `-only-testing:DevDeckTests/PanelLayoutTests`, **1 test, 0 failures, exit 0**, review-corrections-layout.log, xcresult Test-DevDeck-2026.10.27_21-08-28-+0300.xcresult. Native screenshots сохранены в corrections-live/layout-screenshots. Не считать их наблюдением новой standalone app.
- **PASS:** git diff --check.
- **PASS:** отдельный production runner smoke-check `swiftc DevDeck/Process/ProcessTree.swift DevDeck/Process/MonitoringCommand.swift .stage6-current-artifacts/corrections-live/ProcessCheck.swift -o .../process-check`, затем запуск с owned evidence directory. Окончательный process-check-final-clean.log: timeout 5.0059 s, cancel 0.0145 s, parent-exit 0.0250 s; во всех трёх случаях child_alive=false. Вариант process-check-final.log использовал старый PID file для cancel и не засчитывается; исправлен только smoke script, clean прогон создаёт новый PID file каждый раз. Unit tests реальных subprocesses не запускают.
- **PASS:** fresh build: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -project DevDeck.xcodeproj -scheme DevDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .stage6-current-artifacts/corrections-live/build PRODUCT_BUNDLE_IDENTIFIER=local.devdeck.monitoring-development CODE_SIGNING_ALLOWED=NO build`, exit 0, BUILD SUCCEEDED. Подписана ad-hoc только эта новая app. Build identity/codesign в corrections-live/build-identity.json и codesign-identity.txt.
- **UNVERIFIED / BLOCKED:** focused real UI Energy health и System/Light/Dark на новой app. При проверке текущий host helper сообщает `AXTrusted=false ScreenCapture=false` (corrections-live/automation-permissions.txt). Никаких Allow/переключателей/reset не нажималось. Старый stage5 grant не трогался. Нужен доступ AX/ScreenCapture именно host automation-контекста, не повторное добавление dev app в Accessibility вслепую.
- **UNVERIFIED:** полный suite текущего исправленного среза **не запускался**. OS sleep/wake/смена пользовательского engine/live discharge не провоцировались. Независимое повторное ревью исправлений не запускалось этим writer.

### Новая app и состояние окружения

Свежая app: `<worktree>/.stage6-current-artifacts/corrections-live/build/Build/Products/Debug/DevDeck.app`; bundle local.devdeck.monitoring-development, PID **32079**, новый пустой data directory corrections-live/data. Commands=0, chains=0; пользовательские службы не запускались. Прежний owned stage6 PID30115 штатно завершён после проверки его bundle/path; установленный DevDeck и stage5 .acceptance-app не затронуты. SHA256 stage5 executable/dylib повторно совпали с первоначальными.

Новая app executable SHA256: `79a6ac2f77b1b45c9557fa0463fb8672c28bf5f86f043579fb583a7e436067f6`; debug dylib: `f1cb0b62158062f5c9156d53fa2f6915bd192867c2b85b33c09f9372c730868f`. App запущена с дефолтным monitoring enabled, но General page без UI reader; background Energy lifecycle сохранён. Clipboard не использовался.

Touched corrections: DeckMonitoringModel, ProcessManager, MonitoringCommand (new), VMMemory/MinikubeMemory/VMDisk/ClusterHealth, MonitoringSample, MonitoringMetricsView, PopoverView, MenuBarController, PopoverAppearanceBinding (new), DeckMonitoringModelTests, MonitoringReviewTests (new), этот отчёт. Актуальный полный stage6-owned patch и manifest обновляются после GREEN относительно baseline этапов 3–5; точные hashes — review-corrections-identity.json. Коммитов/stage/push/merge/main writes, workers и новых рабочих сессий нет.

## Финальные исправления и приёмка — 31 октября 2026

**Актуальный итог: PASS по порученным исправлениям, полному suite и focused live acceptance.** Этот раздел заменяет прежние UNVERIFIED для полного suite, automation rights, Energy health, System/Light/Dark, reopen и compact memory stopped status. Новое независимое ревью не запускалось: прочитан финальный `.revust/tasks/devdeck-stage6-monitoring/02-after-fix/report.md`, бюджет двух раундов исчерпан.

### Исправления и регрессии

- **PASS — production heavy cadence.** `invalidate()` отменяет heavy task, сохраняя `lastHeavy`. Закрытие последнего reader, interval/master change и suspend/resume сохраняют start-to-start spacing ≥15 s. Сброс оставлен только при изменении container gates, engine или его running state. Регрессия `testProductionHeavyCadenceRetainsStartAcrossCloseAndIntervalChange` использует настоящий `heavySample` lifecycle, удержанную continuation и управляемые часы: старт при t=100, отмена через close/reopen либо interval change, освобождение старой работы, запрет нового старта при t=114, разрешение при t=115. Старая реализация дала два assertion failures; исправленная проходит. Старый cancellation test тоже переведён на controlled time с продвижением часов перед изменением engine.
- **PASS — battery fixture.** `testPublicBatteryConditionHasPriorityAndDoesNotUseUPS` содержит оба поля одновременно: `BatteryHealthCondition=""`, `BatteryHealth="Check Battery"`; ожидается `Check Battery`. Сам selector менять не потребовалось.
- **PASS — подтверждённая run/UI гонка.** Ранее после `finishRun` UI мог стартовать, пока run probe находился в await; старый run затем затирал кеш. VM/disk/minikube теперь используют общий `probeOwners`, удерживаемый до возврата `MonitoringProbeWork.perform`, то есть включая subprocess cleanup. UI ждёт освобождения слота через continuation; отменённый waiter после пробуждения не запускает работу. Run резервирует слот до await и освобождает после cleanup; до публикации проверяет revision/cancellation и наличие active run, minikube дополнительно требует текущие targets. При занятом VM слоте run больше не затирает UI cache значением nil. Между освобождением и guard/publication нет await: новый UI результат не может быть перезаписан старым run результатом.
- Регрессия `testRunToUIHandoffWaitsForCleanupAndPublishesFreshValue` отдельно проходит VM, disk и minikube: удерживает первый run probe (11), завершает последнюю fake-команду, запрашивает UI refresh до освобождения probe, затем освобождает его; проверяет отсутствие overlap и финальный fresh cache=22. До фикса были overlap и stale publication failures; после фикса все три сценария проходят. Реальные команды эти fixtures не запускают.

### Проверенные callers и границы

Поиск сохранён в `.stage6-current-artifacts/final-stage6-callers.txt` и `final-acceptance/ownership-callers.txt`. Production callers общих refresh: heavy chain в `DeckMonitoringModel` и initial/manual/post-action refresh в `CleanupView`; они уже await-ят методы и теперь корректно ждут освобождения run owner. VM/minikube sampler стартует из started events обычной команды/terminal chain и gate invalidation; nil-task guard сохранён. Синхронные `recordVMSample`/`recordMinikubeSample` вызываются только тестами. `refreshVMBuildConfig` в CommandEditor читает отдельную build configuration и не публикует monitoring sample. Host rates и UI-only cluster сохраняют прежние правила; расширения функциональности, изменений engine/proxy/process launch contracts нет. Комментарии к прежним этапам выше являются историей, не новым ограничением focused acceptance.

### Команды и test evidence

Общий префикс всех test запусков:

```sh
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .stage6-current-build CODE_SIGNING_ALLOWED=NO
```

- **RED, ожидаемый:** только две новые lifecycle-регрессии через `-only-testing:DevDeckTests/<Class>/<test>`, `final-stage6-red.log`, exit 65: 2 tests, 6 assertion failures. Xcresult `Test-DevDeck-2026.10.31_13-52-29-+0300.xcresult`. Это доказательство воспроизведения, не финальный FAIL.
- Первый целевой прогон с исправлением: `final-stage6-targeted.log`, 34 tests, 1 failure в старой cancellation fixture: fake clock продвигался после engine-triggered fresh start, разрешая третий sample. Исправлен порядок часов в fixture; production код по этому failure не менялся.
- **PASS — targeted:** `final-stage6-targeted-green.log`, exit 0, **34 tests, 0 failures**. К общему префиксу добавлены `-only-testing:DevDeckTests/<Class>` для MonitoringReviewTests, MonitoringRefreshRaceTests, DeckMonitoringModelTests, ProcessManagerVMSamplerTests, ProcessManagerDiskTests, ProcessManagerMinikubeRefreshTests, ProcessManagerHostMemoryTests, MonitoringSnapshotTests. Xcresult `.stage6-current-build/Logs/Test/Test-DevDeck-2026.10.31_13-54-22-+0300.xcresult`.
- **PASS — полный suite, один запуск на финальных исходниках:** общий префикс без `-only-testing`, `final-stage6-full-suite.log`, exit 0, **929 tests, 0 failures, TEST SUCCEEDED**. Xcresult `.stage6-current-build/Logs/Test/Test-DevDeck-2026.10.31_13-54-46-+0300.xcresult`. PanelLayoutTests занял 116.624 s; read-only stack sample (`final-acceptance/full-suite-panel-sample.txt`) показывает рекурсивный поиск native view, helper идентичен baseline этапов 3–5; тест прошёл. Это не monitoring deadlock и не failure. Последующих правок Swift-исходников не было; hashes `sources-before-live.json` и `sources-after-live.json` совпадают.
- **PASS:** `git diff --check`. Первоначальный sandbox preflight xcodebuild не смог писать системные module/package caches; actual RED/GREEN/full выполнены с необходимым доступом к Xcode runner/cache. Это ограничение окружения, не test failure.

### Focused live acceptance новой app

Новая app: `.stage6-current-artifacts/final-acceptance/build/Build/Products/Debug/DevDeck.app`, bundle **local.devdeck.monitoring-development**, PID при проверке **36372**. Собрана командой:

```sh
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -project DevDeck.xcodeproj \
  -scheme DevDeck -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .stage6-current-artifacts/final-acceptance/build \
  PRODUCT_BUNDLE_IDENTIFIER=local.devdeck.monitoring-development CODE_SIGNING_ALLOWED=NO build
```

`final-acceptance/build.log`: BUILD SUCCEEDED, exit 0. Подписана ad-hoc только эта новая app (`sign.log`). Запуск через `final-acceptance/launch.swift`, `/usr/bin/open -n <new-app> --args --dev-data-directory <absolute-final-acceptance/data>`; commands/chains пусты, clipboard/hotkey/proxy/restore отключены, container probes для focused UI fixture отключены. Пользовательские services/команды не запускались. Helper `final-acceptance/ui.swift` проверяет точные PID, bundle и путь app перед действиями.

| Проверка | Итог и evidence в final-acceptance/ |
| --- | --- |
| Automation rights, один check | **PASS:** `automation-permissions.txt`: AXTrusted=true, ScreenCapture=true. Helper permissions → Python executable → codex → `/Applications/Guild.app/Contents/MacOS/guild-desktop`. Reset, запросы grant и изменение TCC не выполнялись |
| Energy health | **PASS:** текущий `public-health.json`: Condition пуст, Health=Check Battery. `final-energy.txt` и `final-energy-58330.png`: `Battery condition, Check Battery`. Скриншот просмотрен |
| System/Light/Dark popover | **PASS:** `final-theme-{System,Light,Dark}-58341.png` и corresponding main window `*-58330.png`, radio selection проверен helper. System и Dark — тёмные; Light — светлый и у окна, и у popover. Скриншоты просмотрены; системная тема read-only в `system-appearance.txt`; после проверки восстановлен System |
| Compact memory stopped | **PASS:** `compact-stopped-root.txt`, `compact-stopped-58341.png`: retained 31.3 / 48 GB, 65%, `Monitoring is disabled · Last measurement: 13:58:18`; подпись читаема |
| Close/reopen при master off | **PASS:** `stopped-closed-windows.txt` не содержит popover; `stopped-reopened-{first,later}-root.txt` и screenshots сохраняют ту же память и исходный timestamp 13:58:18. После открытия/ожидания timestamp не обновляется |
| Close/reopen при master on | **PASS:** `running-closed-windows.txt` без popover; `running-reopened-first-root.txt`: Measured 13:59:45, первая CPU delta unavailable; `running-reopened-later-root.txt`: Measured 13:59:49, CPU busy 60.4%. Скриншоты просмотрены: сбор возобновился, фиктивного первого CPU значения нет |

После приёмки popover закрыт, новая owned stage6 app штатно завершена через проверенные PID+path (`stop.swift`, `stop.log`). Бинарник и отдельные данные сохранены для повторного ручного запуска. Установленный DevDeck и стабильная stage5 app не останавливались и не изменялись.

### Артефакты и ограничения

Обновлены `.stage6-current-artifacts/stage6-owned.patch`, `stage6-owned-files.json` относительно неизменённого baseline этапов 3–5; предыдущие копии сохранены с префиксом `before-final-stage6-`. Текущая identity — `final-stage6-identity.json`, live hashes — `final-acceptance/evidence-manifest.json`. Они включают финальные source/patch/log/app identities; исторический review-corrections identity сохранён. `protected-before.json`/`protected-after.json` совпадают: main ref и SHA256 всех файлов `.acceptance-app/DevDeck.app` неизменны; stage5 executable/dylib также совпали с предыдущим review identity.

**FAIL:** нет на финальном срезе. **UNVERIFIED:** физический sleep/wake, reboot, пользовательская смена container engine/нагрузка реальных build-команд в этой focused live-приёмке не провоцировались; lifecycle/gates проверены детерминированными fixtures. Дополнительных reviews, workers, worktrees, коммитов, stage, push, merge, TCC reset не было.
