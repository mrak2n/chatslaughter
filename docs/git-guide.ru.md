# Git и GitHub на примере chatslaughter

Git хранит историю проекта локально. GitHub хранит удалённый репозиторий и
предоставляет pull requests, issues, CI и releases. Это разные инструменты.

## Что уже сделано

```sh
git init -b main
git config user.name mrak2n
git config user.email infeduis@mail.ru
```

`init` создаёт каталог `.git`. `main` — основная ветка. Настройки автора действуют
только в этом репозитории. Email попадёт в публичные коммиты после push.
`.gitignore` исключает сборки, локальные базы и файлы сессий. Он не удаляет
секреты из уже созданных коммитов.

## Первый снимок проекта

Выполнено при подготовке проекта: просмотр файлов, тесты, добавление в индекс
и коммит. Актуальный идентификатор можно узнать командой `git log`.

```sh
git status --short
git diff
git add .gitignore Package.swift Sources Tests scripts docs .github README.md README.ru.md LICENSE THIRD_PARTY_NOTICES.md
git diff --cached --stat
git diff --cached --check
git commit -m "Build native macOS chat cleanup preview"
```

Три состояния: рабочие файлы → индекс (`git add`) → сохранённая история (`git commit`).
`git diff` показывает изменения, ещё не включённые в индекс;
`git diff --cached` — точное содержимое будущего коммита.
Коммит сохраняет файлы локально. `push` передаёт коммиты на GitHub.

## Подключение GitHub

После создания пустого публичного репозитория `mrak2n/chatslaughter`:

```sh
git remote add origin https://github.com/mrak2n/chatslaughter.git
git push -u origin main
```

Эти команды выполняются один раз. `origin` — локальное имя удалённого репозитория.
`-u` связывает ветку с удалённой: следующие отправки — просто `git push`.
GitHub не принимает пароль аккаунта при HTTPS push. Используй GitHub CLI
(`gh auth login`) либо настроенный SSH-ключ. Не вставляй токен в URL remote.

## Каждое следующее изменение

Пример: добавление сортировки таблицы.

```sh
git switch main
git pull --ff-only
git switch -c feat/chat-sorting
# Изменить код.
./scripts/test.sh
git diff --check
git diff
git add Sources Tests
git commit -m "Add chat sorting by last activity"
git push -u origin feat/chat-sorting
```

Открой pull request из `feat/chat-sorting` в `main`. PR — предложение включить
изменения ветки. GitHub Actions проверяет тесты и сборку. После проверки выполни
merge в GitHub, затем обнови локальную основную ветку:

```sh
git switch main
git pull --ff-only
git branch -d feat/chat-sorting
```

`--ff-only` не создаёт неожиданный merge-коммит при скачивании истории.
Если команда отказала, сначала посмотри `git status` и
`git log --oneline --graph --all -12`.

## Безопасное исправление ошибок

```sh
git log --oneline -8        # Последние коммиты.
git diff --stat            # Какие файлы изменились.
git restore --staged PATH  # Убрать файл из индекса; сохранить его изменения.
git revert COMMIT          # Новый коммит, отменяющий указанный старый коммит.
```

`git restore PATH` уничтожает несохранённые изменения выбранного файла — используй
только после просмотра diff. Для опубликованной истории предпочитай `revert`;
не используй `reset --hard` и force push как способ «просто исправить ошибку».

## Минимальная практика

1. Создай ветку `docs/first-change`.
2. Добавь одну полезную строку в README.ru.md.
3. Посмотри `git diff`, затем добавь файл через `git add README.ru.md`.
4. Сравни `git diff` и `git diff --cached`.
5. Сделай коммит, push и pull request.

Контрольный вопрос: файл сохранён в редакторе, но `git add` ещё не выполнен.
Где изменение? В рабочем каталоге; в следующий коммит оно пока не попадёт.
