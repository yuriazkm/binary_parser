# Сбор артефактов IPA в Codemagic

После настройки Codemagic автоматически находит собранный IPA, собирает артефакты, упаковывает их в ZIP и отправляет на сервер. Вводить команды или параметры при каждом билде не нужно: значения берутся из окружения сборки.

## 1. Добавьте скрипт в репозиторий

Поместите `binary_parser.sh` в корень проекта и сохраните его в репозитории. Если скрипт уже есть, замените его новой версией. Выдавать разрешение на выполнение вручную не нужно.

## 2. Подключите переменные окружения

В нужном workflow файла `codemagic.yaml` добавьте группу `ipa_processing` в секцию `environment`. Если секция или список групп уже есть, дополните их:

```yaml
environment:
  groups:
    - ipa_processing
```

В группе `ipa_processing` должны быть настроены значения для отправки на сервер:

| Переменная | Назначение |
| --- | --- |
| `IP_DOMAIN` | Домен сервера |
| `IP_IP` | IP-адрес сервера |
| `IP_SECRET_KEY` | Ключ доступа к API |
| `IP_BASE_URL` | Базовый URL для загрузки |

Используйте существующие значения. Не вставляйте ключ доступа в репозиторий. Переменную `CM_BUILD_DIR` предоставляет Codemagic автоматически.

## 3. Укажите, где сборка сохраняет IPA

Для стандартной Flutter-сборки дополнительные настройки не нужны: шаг ищет IPA в `$CM_BUILD_DIR/build/ios/ipa`.

Если ваш workflow сохраняет IPA в другом месте, добавьте в окружение Codemagic переменную `IPA_SEARCH_DIR` с путём к каталогу экспорта. Это относится и к Native/Unity-сборкам. Каталог должен содержать один IPA.

Если сборка создаёт несколько IPA, задайте переменную окружения `IPA_PATH` с точным путём к нужному файлу. Она имеет приоритет над `IPA_SEARCH_DIR`. Путь можно также установить автоматически командой `export IPA_PATH="..."` внутри шага ниже перед поиском IPA, используя переменные вашего workflow.

Эти параметры настраиваются один раз под существующий процесс сборки; перед каждым запуском вводить их не требуется.

## 4. Добавьте шаг обработки после сборки IPA

В секцию `scripts` нужного workflow вставьте следующий шаг **после команды, которая экспортирует готовый `.ipa`**. Если шаг `Process ipa` уже существует, замените его. Соблюдайте отступы относительно остальных шагов в вашем YAML.

Тот же фрагмент находится в файле `codemagic-step.yaml`.

```yaml
- name: Process ipa
  script: |
    set -euo pipefail
    if [[ -z "${IPA_PATH:-}" ]]; then
      IPA_SEARCH_DIR="${IPA_SEARCH_DIR:-$CM_BUILD_DIR/build/ios/ipa}"
      [[ -d "$IPA_SEARCH_DIR" ]] || { echo "IPA directory not found: $IPA_SEARCH_DIR"; exit 1; }
      IPA_LIST=$(mktemp)
      find "$IPA_SEARCH_DIR" -type f -name '*.ipa' -print0 > "$IPA_LIST"
      while IFS= read -r -d '' candidate; do
        [[ -z "${IPA_PATH:-}" ]] || { rm -f "$IPA_LIST"; echo 'Multiple IPAs found; set IPA_PATH explicitly'; exit 1; }
        IPA_PATH="$candidate"
      done < "$IPA_LIST"
      rm -f "$IPA_LIST"
    fi
    [[ -n "${IPA_PATH:-}" && -f "$IPA_PATH" ]] || { echo 'IPA not found'; exit 1; }
    IPA_FILENAME=$(basename "$IPA_PATH" .ipa)
    RUN_DIR=$(mktemp -d "$CM_BUILD_DIR/ipa-artifacts.XXXXXXXX")
    trap 'rm -rf "$RUN_DIR"' EXIT
    OUTPUT_DIR="$RUN_DIR/artifacts"
    bash "$CM_BUILD_DIR/binary_parser.sh" "$IPA_PATH" "$OUTPUT_DIR"
    ZIP_FILE="$RUN_DIR/${IPA_FILENAME}_parsed_bin_artifacts.zip"
    (
      cd "$OUTPUT_DIR"
      zip -r "$ZIP_FILE" ./*
    )
    curl -X POST \
      --resolve ${IP_DOMAIN}:443:$IP_IP \
      -H "x-api-key: $IP_SECRET_KEY" \
      -F "file=@$ZIP_FILE" \
      "${IP_BASE_URL}<upload_type>"
```

## 5. Выберите адрес загрузки для типа приложения

В последней строке шага замените `<upload_type>` на значение из таблицы. `${IP_BASE_URL}` оставьте без изменений — его значение подставляется из окружения.

| Тип приложения | Подписочные | Вебвью | Сошиал | Спешиал |
| --- | --- | --- | --- | --- |
| Native iOS (Swift/Objective-C) | `upload_nwa` | `upload_nww` | `upload_nsc` | `upload_nsp` |
| Flutter iOS | `upload_fwa` | `upload_fww` | `upload_fsc` | `upload_fsp` |
| Unity iOS | `upload_uwa` | `upload_uww` | `upload_usc` | `upload_usp` |

Например, для подписочного Flutter-приложения строка должна выглядеть так:

```bash
"${IP_BASE_URL}upload_fwa"
```

При обновлении уже настроенного workflow сохраните прежний адрес загрузки для этого приложения.

## 6. Запустите сборку в Codemagic

Сохраните изменения в репозитории и запустите ваш обычный workflow. Шаг `Process ipa` выполнит сбор и отправку артефактов автоматически.

Добавлять ZIP в секцию `artifacts` не требуется: он отправляется непосредственно на сервер. Если IPA не найден, найдено несколько файлов без явно заданного `IPA_PATH` или разбор завершился ошибкой, шаг остановится до отправки. Причину можно посмотреть в логе `Process ipa`.

## Дополнительно: локальный запуск

Для локального сбора нужен macOS с установленными Xcode Command Line Tools. Выполните из каталога со скриптом:

```bash
bash binary_parser.sh '/path/My App.ipa' '/path/output'
```

Укажите путь к IPA и пустой выходной каталог. Если каталога нет, скрипт создаст его. Локальный запуск сохраняет файлы артефактов в этот каталог; упаковку и отправку на сервер выполняет отдельный шаг Codemagic, приведённый выше.
