import Foundation

/// The Cleanup page's Mac-disk part: the disk bar, the scan, the categories and the deletion.
extension L10n {
    static var macDisk: String { t("Mac disk", "Диск Mac") }
    static func macFilesCommandName(count: Int) -> String {
        t("Cleanup: Mac files (\(count))", "Очистка: файлы Mac (\(count))")
    }

    // Scan

    static var diskScan: String { t("Scan", "Сканировать") }
    static var diskScanStop: String { t("Stop Scan", "Остановить") }
    static var diskNeverScanned: String {
        t("Not scanned yet — Scan walks the home folder and shows what can be freed and where the rest is.",
          "Ещё не сканировали — «Сканировать» обойдёт домашнюю папку и покажет, что можно освободить и где остальное.")
    }
    static func diskScanning(files: String, size: String, current: String?) -> String {
        let base = t("Scanning: \(files) files · \(size)", "Сканирование: \(files) файлов · \(size)")
        guard let current else { return base }
        return base + " · ~/" + current
    }
    static func diskScanned(date: String, files: String) -> String {
        t("Scanned \(date) · \(files) files", "Сканировано \(date) · \(files) файлов")
    }
    static func diskPartial(_ count: Int) -> String {
        t("Partial: \(count) folders could not be read", "Частично: недоступно папок — \(count)")
    }
    static var diskSkippedTitle: String { t("Not scanned — protected by macOS", "Не просканировано — защищено macOS") }
    static var diskSkippedNote: String {
        t("macOS asks for permission before an app may look inside these folders. DevDeck does not ask, so their size is not known.",
          "macOS спрашивает разрешение, прежде чем приложение заглянет в эти папки. DevDeck не спрашивает, поэтому их размер неизвестен.")
    }
    static var diskUnreadable: String { t("not readable", "недоступно") }

    // Candidates

    static var diskCanFree: String { t("Can be freed", "Можно очистить") }
    static var diskCanFreeEmpty: String { t("Nothing known to free.", "Ничего известного для очистки.") }
    static var diskCanFreeNote: String {
        t("Build output and caches DevDeck knows how to recreate. Deleted at once, not moved to the Trash. Nothing is selected until you select it.",
          "Сборки и кеши, которые пересоздаются. Удаляются сразу, без Корзины. Пока вы не отметите — ничего не выбрано.")
    }
    static func diskFreeSelected(_ size: String) -> String {
        t("Free Selected · \(size)", "Очистить выбранное · \(size)")
    }
    static func diskSmallCandidates(count: Int, size: String) -> String {
        t("and \(count) smaller ones · \(size)", "и ещё мелких: \(count) · \(size)")
    }
    static func diskCategoryTitle(_ category: DiskCategory, project: String?) -> String {
        switch category {
        case .rustTarget: return "Rust target · " + (project ?? "")
        case .nodeModules: return "node_modules · " + (project ?? "")
        case .libraryCaches: return "~/Library/Caches"
        case .userCache: return "~/.cache"
        case .goModules: return t("Go modules", "Go-модули")
        case .minikubeCache: return "~/.minikube/cache"
        case .xcodeDerivedData: return "Xcode DerivedData"
        case .npmCache: return t("npm cache", "Кеш npm")
        case .gradleCaches: return t("Gradle caches", "Кеши Gradle")
        case .cargoRegistry: return "Cargo registry"
        }
    }
    /// What deleting it costs afterwards.
    static func diskCategoryCost(_ category: DiskCategory) -> String {
        switch category {
        case .rustTarget: return t("the project rebuilds from scratch", "проект пересоберётся с нуля")
        case .nodeModules: return t("install dependencies again", "зависимости нужно установить заново")
        case .libraryCaches: return t("apps recreate it; quit browsers and IDEs first", "приложения пересоздадут; лучше сначала закрыть браузеры и IDE")
        case .userCache: return t("downloaded again on use — may hold models", "скачается заново при использовании — там могут быть модели")
        case .goModules: return t("modules are downloaded again", "модули скачаются заново")
        case .minikubeCache: return t("images are downloaded again on minikube start", "образы скачаются заново при minikube start")
        case .xcodeDerivedData: return t("Xcode rebuilds", "Xcode пересоберёт")
        case .npmCache: return t("packages are downloaded again", "пакеты скачаются заново")
        case .gradleCaches: return t("dependencies are downloaded again; the first build is long", "зависимости скачаются заново, первая сборка долгая")
        case .cargoRegistry: return t("crates are downloaded again", "crates скачаются заново")
        }
    }
    static func diskModified(_ age: String) -> String { t("changed \(age) ago", "изменён \(age) назад") }
    static var diskMaybeBuilding: String { t("a build may be running", "возможно, идёт сборка") }

    // Largest folders

    static var diskLargest: String { t("Largest folders", "Крупнейшие папки") }
    static var diskLargestNote: String {
        t("Measured only. DevDeck deletes nothing here — open a folder in Finder to decide.",
          "Только размеры. Здесь DevDeck ничего не удаляет — откройте папку в Finder и решите сами.")
    }
    static var diskOther: String { t("other", "прочее") }
    static var diskShowInFinder: String { t("Finder", "Finder") }
    static var diskVMDiskLabel: String { t("VM disk", "диск VM") }

    // Confirmation

    static var diskConfirmTitle: String { t("Delete for good?", "Удалить безвозвратно?") }
    static var diskConfirmNote: String {
        t("Deleted at once, not moved to the Trash. This cannot be undone.",
          "Удаление сразу, без Корзины. Отменить нельзя.")
    }
    static func diskConfirmDelete(_ size: String) -> String { t("Delete · \(size)", "Удалить · \(size)") }
    static var diskConfirmSkipped: String { t("Skipped", "Пропущено") }
    static func diskRejection(_ reason: DeletionRejection) -> String {
        switch reason {
        case .outsideHome: return t("outside the home folder", "вне домашней папки")
        case .missing: return t("no longer exists", "больше не существует")
        case .notADirectory: return t("no longer a folder", "больше не папка")
        case .symlink: return t("replaced by a link", "заменена ссылкой")
        case .symlinkedAncestor: return t("reached through a link", "путь идёт через ссылку")
        case .otherVolume: return t("on another volume", "на другом томе")
        case .noLongerMatches: return t("no longer what the scan found", "уже не то, что нашёл скан")
        case .buildRunning: return t("a cargo build is running", "идёт сборка cargo")
        }
    }
    static var diskAfterRun: String {
        t("Sizes may have changed — scan again for exact figures.",
          "Размеры могли измениться — пересканируйте для точных цифр.")
    }
}
