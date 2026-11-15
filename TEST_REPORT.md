# Проверка MVP — 15.11.2026

Проект: Flutter 3.44.6 / Dart 3.12.2, Node.js 25.9.0, JDK 17, compileSdk 37. Android-прогон: эмулятор API 35 (arm64). OpenAI API использовался реально; тестовые doubles применяются только в обычном `npm test` и Flutter unit/widget tests.

## Успешно

- **14 серверных тестов**: HTTP/WS token auth и изоляция данных тестовых клиентов; идемпотентное принятие и конфликт ключа; снимок знаний при принятии; независимость worker от подтверждённого закрытия Live; доставка completion по отдельному WebSocket; обработка вложенного Responses function call, дедупликация и продолжение; ограничение очереди; восстановление JSON после перезапуска; поведение прерванных Running; результат и правила в новой конфигурации; lease timeout; task timeout; явный Unconfirmed без `session.closed`; сохранение точного CRLF в SDP.
- **5 Flutter unit/widget tests**: безопасное состояние без настроенного backend; показ пропущенного результата после HTTP sync без запуска голоса; постоянная обработка «Позже»; явное создание новой сессии по «Ответить» после получения результата; sync при reconnect и защита от устаревшего статуса; повтор отправки с прежним idempotency key. Несколько проверок объединены в одном тесте.
- **Реальный Responses smoke**: вопрос по `data.txt` вернул Project Alpha, результат сохранён. Response ID: `resp_03be8e5cd18751cd016af9f761a29087d2b3ce8ae57eb8e287`. Usage: 340 input + 11 output = 351 tokens. Повтор POST с прежним ключом сохранил один task ID. Результат остался после перезапусков backend.
- **Реальный Android integration test** `integration_test/live_flow_test.dart`: WebRTC с `gpt-live-1` → Connected; создание настоящего текстового отчёта → End; подтверждённое закрытие первой сессии; завершение worker после закрытия голоса; callback в открытом UI; «Позже» без новой сессии; «Ответить» с точным результатом и новым session ID; получение реальных output transcript deltas; подтверждённое закрытие второй сессии. Тест завершился `All tests passed`.
- В том Android-прогоне обе сессии получили `session.closed`, `reason: close_requested`, API usage по 15 секунд (учитывая WebRTC initialization accounting). Отчёт вызвал Responses отдельно: 357 input + 141 output = 498 tokens. Это не оценка стоимости по таймеру UI.
- Сервер сохранил output transcript fragments новой сессии. После прогона **нет неподтверждённых или активных Live-сессий** в хранилище.
- Debug и финальный release APK собраны и установлены на эмулятор. Release APK (86.6 MB) запущен, проверены настройки подключения, WebSocket и голосовой Start/End. SHA256: `69d16521c39ae0312cd281715606fc56fe399567d8c3d520482a9694e51985bc`.
- **Дополнительный реальный release smoke native Responses tool**: в открытую Live-сессию через trusted sideband добавлен backend-текст запроса и запущен `response.create`. Настоящая модель вызвала `enqueue_text_task`; production handler зарегистрировал самостоятельный job `d7f812a3-5b25-476f-963e-8a2546ce4333`, отправил function output и продолжил Responses. Голос закрыт с подтверждёнными 21 секундами usage, worker завершился после закрытия, release UI показал входящий звонок. Этот smoke проверяет настоящий model/tool/worker поток; он не проверяет распознавание устной просьбы.
- `.env`, runtime storage, тестовые credentials, APK/build и `node_modules` исключены из Git. Проверка исходных файлов не нашла OpenAI key prefixes. Ключ не передавался в Flutter dart-defines; дополнительная проверка всех распакованных entries release APK не обнаружила текущий OpenAI API-ключ.

## Обнаружено и исправлено

1. Первая Android-сборка выявила требование permission_handler_android к compileSdk 37. Настройка обновлена; следующая сборка прошла.
2. Первый реальный Live-запрос получил HTTP 400. Обнаружена обработка SDP через `trim()`, которая удаляла завершающий CRLF. SDP теперь передаётся без изменения; добавлен регрессионный тест. Повторный реальный WebRTC-прогон прошёл.
3. В первоначальном widget test кнопка находилась ниже области экрана теста; исправлен размер/scroll тестового viewport.
4. Тестовый HTTP double не задавал UTF-8 для русского JSON; исправлены заголовки fixture. Производственный HTTP-клиент уже декодировал UTF-8 правильно.
5. Исключены регресс статуса Running → Queued от запоздавшего HTTP-ответа и завершение новой сессии из-за ошибки старого heartbeat.

## Проверяется вручную на физическом телефоне

- Качество звука, speaker routing, задержка и возможность перебить ассистента живым голосом, включая короткие «угу/ага/подожди».
- Постановка задания именно по устной просьбе: application-owned handler проверен с официальной формой событий в серверном тесте и с настоящим native Responses function call в release smoke; Android integration создавал задание через текстовый HTTP-путь. Спонтанное native delegation голосовой моделью от настоящей речи в эмуляторе не проверялось.
- Ответ Project Alpha именно на произнесённый вопрос и смена произносимого языка после правки rules.md. Текстовая модель по реальному API и формирование новой конфигурации проверены отдельно.
- Слышимость сигнала/вибрации при различных настройках Android и фактическое прослушивание результата человеком. Output transcript — свидетельство работы генерации, а не подтверждение, что пользователь услышал звук.
- Возврат после физической блокировки/убийства приложения и длительного LAN-разрыва на выбранном устройстве. Механизм HTTP reconciliation/сохранения результатов проверен тестами.

Из известных ограничений реализации: нет необязательной отмены задач; прерванный Running после restart не повторяется автоматически; одинаковое голосовое задание дедуплицируется в пределах conversation; не реализованы push, системные звонки, веб-поиск, внешние приложения, изменение кода, публичная многопользовательская авторизация. Это локальный Android MVP, а не production-сервис.

Сборка выдаёт предупреждение flutter_webrtc о применении Kotlin Gradle Plugin и будущей миграции на Built-in Kotlin. В текущей версии Flutter оно не мешает сборке и работе. Release подписывается debug-ключом для локального тестирования.

## macOS build and launch

- Added the native macOS runner, a 540×860 window, microphone usage description and sandbox network/audio-input entitlements.
- macOS microphone access uses flutter_webrtc's native AVCaptureDevice request; permission_handler remains used on supported mobile platforms.
- macOS defaults to `http://127.0.0.1:8789`; the local build uses only the backend dev token from an ignored defines file. The OpenAI key stays on the server.
- `flutter analyze`: no issues. All 5 Flutter tests passed after these changes.
- `flutter build macos --release --dart-define-from-file=../artifacts/macos-defines.json`: passed. App size reported by Flutter: 74.8 MB.
- `codesign --verify --deep --strict`: passed for both the build output and `dist/GPT Live.app`.
- Launched `dist/GPT Live.app` and inspected its native UI: window GPT Live, Disconnected voice status, Start Conversation button and task WebSocket status «На связи». No microphone or paid voice session was started during this launch check.
- Build emitted an objective_c native asset warning about architecture-specific framework names; it did not prevent packaging or launch. Live audio on macOS has not been exercised by this launch-only check.

## Повторная проверка на Mac

- На этом Mac повторно выполнены `npm test` (14/14), `flutter test` (5/5), `flutter analyze` (без замечаний) и `codesign --verify --deep --strict dist/GPT Live.app` (успешно).
- Release-приложение показывает основной экран и подключённый отдельный WebSocket задач («На связи»).
- Нажатие Start Conversation перевело UI в Connecting. Операция получения микрофона ожидает системного разрешения; новой Live-сессии в backend storage на момент проверки нет. Это ещё не успешная проверка голоса.
- Computer Use вернул явный запрет доступа к `com.apple.UserNotificationCenter` по своему правилу безопасности. Системный диалог не обходился; пользователю предложено вручную разрешить микрофон для GPT Live.
- До этого действия остаются непроверенными на macOS: реальный WebRTC Start/End, звук и перебивания, делегирование из речи, callback после завершения задачи, «Позже»/«Ответить» с новым голосовым подключением. Ранее описанные реальные Android-прогоны не считаются macOS-прогонами.

## Редизайн: warm editorial

- Введена общая светлая тема: бумажный фон, тёмные кнопки, заголовки Georgia с serif fallback, терракотовые и приглушённые зелёные акценты. Обновлены основной экран, настройки, ошибки, карточки задач, чтение результата и входящий вызов.
- От 860 logical pixels разговор и задачи стоят в двух колонках; ниже — вертикально. Начальное macOS-окно увеличено до 1100×800, минимум 400×580 сохранён. Визуально проверены широкое окно, ширина около 500 и минимальная ширина 400: переносы, прокрутка, доступность кнопок и карточек.
- После редизайна `flutter analyze` без замечаний, все 5 Flutter-тестов прошли.
- В release-приложении на Mac через новый текстовый composer запущен настоящий Responses job: Running → Completed → входящий вызов. Нажатие «Позже» вернуло workspace без создания Live-сессии. «Читать результат» показало сохранённые факты: Project Alpha, управление задачами, Flutter и Unity. Проверены внешний вид overlay и reader.
- Это подтверждает на macOS текстовый путь, worker, доставку результата и callback UI. Доступ к микрофону и реальный голос по-прежнему требуют завершения ранее описанной ручной проверки; редизайн не подменяет её.
- Исправлены выравнивание section headers на desktop и фокус/доступность входящего overlay: элементы под ним исключаются из keyboard traversal и accessibility tree. Повторная реальная задача в финальном Mac-build подтвердила, что видны только элементы входящего вызова, а composer теряет фокус; «Позже» снова возвращает обычные элементы.
- Финальные release-сборки macOS (74.8 MB) и Android (86.7 MB) прошли. У incremental macOS build обнаружена устаревшая подпись `App.framework`: framework и bundle повторно подписаны локальной ad-hoc подписью с сохранением entitlements. `codesign --verify --deep --strict` финального `dist/GPT Live.app` прошёл; приложение повторно запущено и визуально проверено. Это локальная сборка, без notarization.
- APK после редизайна, SHA256: `8b9ad6f5b1e79e4adfc5018bac3c262e88bf3093cec30a2cbd0d5af1dc42e5b8`. Проверка текущего OpenAI API-ключа не нашла его в 36 файлах macOS bundle, во всех entries нового APK и в исходниках архива. Исходный ZIP обновлён.

## Исправление реального macOS release WebRTC-сбоя

Предыдущая проверка Mac не подтверждала работоспособность голоса. После сообщения пользователя повторно нажат Start в прежнем release: Connecting → Error, 00:00, сервер подтвердил закрытие с initialization usage. Ошибка воспроизведена.

Причина: в `macos/Runner/Release.entitlements` отсутствовал `com.apple.security.network.server`, который уже был включён в DebugProfile. В sandbox macOS UDP требует обоих сетевых разрешений; HTTP/WS-трафик продолжал работать с одним `network.client`, а WebRTC не устанавливался. Добавлено server-разрешение, sandbox сохранён. Основание: [документация Apple о UDP](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server).

После пересборки и замены `dist/GPT Live.app` проверен именно release:

- Start → Connected, реальный разговор удерживался около двух минут. Сессия `live_u7_EkaR9p3oNOPf9TtxA7bnQ9AnMgjmqz7D` закрыта подтверждённым `session.closed`, usage **128 секунд**, reason `close_requested`.
- В 40-секундном окне наблюдения sideband получил 219 `session.input_audio.append`, 218 `session.output_audio.delta` (2,092,800 байт выходного PCM), input/output transcript deltas и Responses delegation. Полные аудиозаписи и приватный текст в отчёт не сохранялись. Проверена реальная речь с микрофона, а не инъекция текстового запроса.
- «Обсудить» у готового результата открыло другую сессию `live_u7_EkaUdp3oMIPAxLay7RSNRnxjPG5CQeiW`; она перешла в Connected, получила сохранённый результат, в фактическом ответе появился Project Alpha. Затем в UI нажата End Conversation: подтверждённое закрытие, usage **49 секунд**, reason `close_requested`. После обоих прогонов активных сессий нет, UI показывает Disconnected без ошибки.
- Добавлен `scripts/check_macos_release.py`: проверяет подпись и entitlements **подписанного app bundle**, а не только исходный plist. Сохранённый старый bundle предсказуемо не проходит проверку из-за отсутствия network.server, исправленный проходит. В README добавлена команда проверки после сборки.

Этот прогон подтверждает подключение, реальный аудиообмен, новый разговор с результатом и закрытие на Mac. Субъективное качество произношения, акцент и все разновидности коротких перебиваний этим не сертифицируются; во время живого разговора были замечания к произношению. Демонстрационные факты базы также не следует считать проверенными персональными сведениями пользователя.
