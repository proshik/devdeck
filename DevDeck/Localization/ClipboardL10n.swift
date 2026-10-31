import Foundation

extension L10n {
    static var clipboardPaste: String { t("Paste into previous app", "Вставить в предыдущее приложение") }
    static var clipboardPasteEnabled: String { t("Enable paste into previous app", "Вставка в предыдущее приложение") }
    static var clipboardPastePermission: String { t("Allow Accessibility access to paste. Copying remains available.", "Для вставки разрешите Универсальный доступ. Копирование остаётся доступным.") }
    static var clipboardPasteRequest: String { t("Request Accessibility access", "Запросить Универсальный доступ") }
    static var clipboardPasteTargetFailed: String { t("Could not restore the previous app. The entry can still be copied.", "Не удалось вернуть фокус предыдущему приложению. Запись можно скопировать.") }
    static var clipboardPasteChanged: String { t("Clipboard changed before paste; paste was cancelled.", "Буфер изменился перед вставкой; вставка отменена.") }
    static var clipboardPasteOff: String { t("Enable paste in Clipboard settings first.", "Сначала включите вставку в настройках буфера.") }
    static var clipboardPasteCancelled: String { t("Paste cancelled.", "Вставка отменена.") }
    static var clipboardMissingFile: String { t("File is unavailable", "Файл недоступен") }
    static var clipboardImage: String { t("Image", "Изображение") }
    static var clipboardTitle: String { t("Clipboard", "Буфер обмена") }
    static var clipboardTab: String { t("Clipboard", "Буфер") }
    static var clipboardHistory: String { t("Clipboard history", "История буфера") }
    static var clipboardEnabled: String { t("Collect clipboard history", "Собирать историю буфера") }
    static var clipboardOff: String { t("History is off", "История выключена") }
    static var clipboardEnable: String { t("Enable history", "Включить историю") }
    static var clipboardPause: String { t("Pause collection", "Приостановить сбор") }
    static var clipboardResume: String { t("Resume collection", "Возобновить сбор") }
    static var clipboardPaused: String { t("Collection paused", "Сбор приостановлен") }
    static var clipboardSearch: String { t("Find copied content", "Найти скопированное") }
    static var clipboardEmpty: String { t("New copied content will appear here", "Здесь появится новое скопированное содержимое") }
    static var clipboardNoMatches: String { t("No matching entries", "Ничего не найдено") }
    static var clipboardUnknownSource: String { t("Unknown source", "Источник неизвестен") }
    static var clipboardCopy: String { t("Copy to clipboard", "Скопировать в буфер") }
    static var clipboardCopied: String { t("Copied", "Скопировано") }
    static var clipboardPin: String { t("Pin", "Закрепить") }
    static var clipboardUnpin: String { t("Unpin", "Открепить") }
    static var clipboardPinnedOnly: String { t("Pinned only", "Только закреплённые") }
    static var clipboardDelete: String { t("Delete entry", "Удалить запись") }
    static var clipboardClear: String { t("Clear unpinned…", "Очистить незакреплённые…") }
    static var clipboardClearAll: String { t("Delete all history…", "Удалить всю историю…") }
    static var clipboardClearTitle: String { t("Clear clipboard history?", "Очистить историю буфера?") }
    static var clipboardClearMessage: String { t("Pinned entries will be kept. The current system clipboard is unchanged.", "Закреплённые записи останутся. Текущий системный буфер не изменится.") }
    static var clipboardClearAllMessage: String { t("All saved entries, including pinned ones, will be permanently deleted. The current system clipboard is unchanged.", "Все сохранённые записи, включая закреплённые, будут удалены. Текущий системный буфер не изменится.") }
    static var clipboardConfirmDelete: String { t("Delete", "Удалить") }
    static var clipboardCollection: String { t("Collection", "Сбор истории") }
    static var clipboardRetention: String { t("Storage limits", "Лимиты хранения") }
    static var clipboardCountLimit: String { t("Entries", "Количество записей") }
    static var clipboardDaysLimit: String { t("Keep for (days)", "Хранить дней") }
    static var clipboardBytesLimit: String { t("Storage (MiB)", "Объём (МиБ)") }
    static var clipboardLimitsHelp: String { t("Pinned entries survive age limits and ordinary clearing, but count towards the entry and storage limits. Up to 100 pins; text up to 1 MiB per entry.", "Закреплённые записи сохраняются независимо от возраста и обычной очистки, но входят в общий лимит записей и объёма. До 100 закреплений; до 1 МиБ текста в записи.") }
    static var clipboardExclusions: String { t("Excluded applications", "Исключённые приложения") }
    static var clipboardAddApp: String { t("Add application…", "Добавить приложение…") }
    static var clipboardBundleID: String { t("Application bundle ID", "Bundle ID приложения") }
    static var clipboardRemoveExclusion: String { t("Remove exclusion", "Удалить исключение") }
    static var clipboardPrivacyHelp: String { t("History stays on this Mac, outside the command configuration. Marked confidential, transient and generated clipboard data is skipped. Exclusions use declared source or the active app; unmarked secrets cannot be recognized automatically.", "История хранится на этом Mac отдельно от конфигурации команд. Данные с отметками конфиденциальности, временности или автогенерации пропускаются. Исключения проверяют указанный источник или активное приложение; секреты без отметок автоматически не распознаются.") }
    static var clipboardPermission: String { t("For background history, allow ongoing clipboard access for DevDeck in System Settings → Privacy & Security. Choose Always Allow.", "Для фонового сбора разрешите DevDeck постоянный доступ к буферу в Системных настройках → Конфиденциальность и безопасность. Выберите «Разрешать всегда».") }
    static var clipboardRequestAccess: String { t("Request clipboard access", "Запросить доступ к буферу") }
    static var clipboardSystemSettings: String { t("Open System Settings…", "Открыть Системные настройки…") }
    static var clipboardDamaged: String { t("History could not be read. The file has been preserved. Delete all history to reset it explicitly.", "Не удалось прочитать историю. Файл сохранён. Для явного сброса удалите всю историю.") }
    static var clipboardWriteFailed: String { t("Could not save history. The last saved entries are intact. Check available disk space and access to the history folder.", "Не удалось сохранить историю. Последние сохранённые записи целы. Проверьте место на диске и доступ к папке истории.") }
    static var clipboardPinLimit: String { t("Pinned entries exceed the chosen limit. Unpin entries or increase the storage limits.", "Закреплённые записи превышают выбранный лимит. Открепите записи или увеличьте лимиты хранения.") }
    static var clipboardTooLarge: String { t("Content is unsupported, damaged or exceeds its entry limit and was skipped.", "Содержимое не поддерживается, повреждено или превышает лимит записи и пропущено.") }
    static var clipboardCopyFailed: String { t("Could not copy this entry to the clipboard.", "Не удалось скопировать запись в буфер.") }
    static var clipboardRetry: String { t("Retry", "Повторить") }
    static var clipboardShowAll: String { t("Show all history…", "Показать всю историю…") }
    static var clipboardSelectedText: String { t("Select an entry to see its content", "Выберите запись, чтобы увидеть содержимое") }
}

extension L10n {
    static var clipboardText: String { t("Text", "Текст") }
    static var clipboardImages: String { t("Images", "Изображения") }
    static var clipboardFiles: String { t("Files", "Файлы") }
    static var clipboardType: String { t("Content type", "Тип содержимого") }
    static var clipboardAllTypes: String { t("All types", "Все типы") }
    static var clipboardFilesHelp: String { t("Only file references are stored. Moving or deleting a file makes its reference unavailable.", "Хранятся только ссылки на файлы. После перемещения или удаления файла ссылка станет недоступной.") }
    static var clipboardPasteHelp: String { t("Paste is an explicit action. DevDeck closes the panel and restores the previous app before sending Cmd-V.", "Вставка выполняется отдельным действием. DevDeck закрывает панель и возвращает фокус предыдущему приложению перед Cmd-V.") }
}

extension L10n {
    static var clipboardPreviewFailed: String { t("Preview could not be decoded.", "Не удалось прочитать превью.") }
    static var clipboardMediaLimitsHelp: String { t("Images: up to 10 MiB / 40 MP; up to 100 file references per entry. These count towards the total storage limit.", "Изображения: до 10 МиБ / 40 Мп; до 100 ссылок на файлы в записи. Они входят в общий лимит хранения.") }
}
