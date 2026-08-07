repo: fosteev/ollama-bar
branch: main

## Last sync

date: 2026-08-06T12:10:00Z

### Updated in this project

- Спроектирована панель монитора для всех восьми состояний (340 pt).
- Новая логика приоритета: всегда / по событию / раскрывается / отдельное окно.
- Элемент меню-бара дополнен цветовым сигналом предупреждения и ошибки.
- Настройки сокращены до хоста и перехвата, остальное в Advanced.

## Screen map

| Screen | Repo files |
|---|---|
| Панель, все состояния | Sources/App/Views/StatusPanel.swift, Sources/Core/OllamaMonitor.swift, Sources/Core/Models.swift, Sources/Core/Formatting.swift |
| Элемент в строке меню | Sources/App/Views/MenuBarLabel.swift, Sources/App/OllamaBarApp.swift |
| Настройки | Sources/App/Views/SettingsView.swift, Sources/App/Settings/AppSettings.swift |
| Окно истории / разбивка запроса | Sources/Core/LogEvent.swift, Sources/CLI/OllamaBarCLI.swift |
