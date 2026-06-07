# Независимый аудит для поста

Дата: 24 мая 2026  
Объект: Vaulté Privé — iOS-клиент + relay + docs  
Цель: понять, что можно публиковать в посте **сейчас**, а что нельзя до выкладки репозитория / App Store.

---

## Вердикт

| Тип поста | Можно? | Почему |
|-----------|--------|--------|
| Пост про **приложение** (фичи, дизайн, приватность) | **Да, с оговорками** | Продукт собран, privacy policy и implementation docs внутри приложения есть |
| Пост «**выложили код** / open source» | **Нет, рано** | В исходниках до сих пор лежат **живые relay-секреты** |
| Пост «**аудируйте наш OTP**» | **Частично** | Есть in-app docs + `docs/OTP-Implementation.md`, но публичный репо с секретами опасен |

**Главный блокер перед любым постом про код:**  
секреты прод-релея захардкожены в:
- `Vaulté Privé/Vaulté Privé/ChatAPIClient.swift` (`bundledFallback*`)
- `Vaulté Privé/Vaulté Privé.xcodeproj/project.pbxproj` (`INFOPLIST_KEY_VAULTE_RELAY_*`)

Их нужно **убрать из кода**, **ротировать на сервере**, и только потом говорить «код доступен для аудита».

---

## Что реально готово (можно упоминать в посте)

### Продукт

- **E2E-чаты:** X3DH + Double Ratchet (Signal-style), AES fallback для legacy-сессий
- **One Time Pad:** отдельный режим, `.vaultepad`, directional pads, mutual approval, capacity tracking
- **E2E+ удалён** из продукта — в посте не упоминать
- **Группы, фото, исчезающие сообщения** (Elite)
- **Screenshot / copy alerts** (Elite)
- **Звонки** с шифрованием фреймов
- **Premier:** encrypted backup (`.vaultbackup`), local search
- **Удаление чата на обе стороны**
- **Privacy Policy** в Settings — нормальный текст, подпись, implementation files (`E2E-Implementation.md`, `OTP-Implementation.md`)

### Документы

- `PRIVACY_POLICY.md`
- `docs/SECURITY.md`
- `docs/E2E-Implementation.md`
- `docs/OTP-Implementation.md`
- `LICENSE` — source-available, OTP **нельзя** копировать
- `CONTRIBUTING.md`, `README.md`

### Дизайн

- Монохром: чёрный фон + белый акцент (`VaultePalette.gold = white`)
- Звёздный фон, `AMTypewriter`
- Минималистичный shell: табы, settings, premium

---

## Критично — исправить до поста про код

### 1. Секреты в репозитории

**Риск:** любой, кто увидит пост, сможет дергать ваш relay от имени приложения.

**Действия:**
1. Ротировать на Render: API key, HMAC secret, username lookup pepper
2. Удалить `bundledFallback*` из `ChatAPIClient.swift` — только `Secrets.xcconfig` / env / CI
3. Убрать `INFOPLIST_KEY_VAULTE_RELAY_*` из `project.pbxproj`
4. Проверить историю git — если секреты когда-либо коммитились, ротация обязательна даже после удаления

### 2. Папка `Messages 2/` (~339 файлов)

**Риск:** в git index лежит код с паттернами Signal (`OWS*`, `TS*`, attachments v2). Не входит в Xcode target, но при публикации репо создаёт:
- юридический шум (чужой код без явной лицензии в дереве)
- впечатление «скопировали Signal и выкладываем»

**Действия:** удалить из index / не включать в публичный push, либо оформить отдельно с лицензией если это форк.

### 3. Контакт privacy

`privacy@vaulteprive.com` — placeholder. Для App Store и поста нужен **реальный** email.

---

## Высокий приоритет

| # | Проблема | Файл | Для поста |
|---|----------|------|-----------|
| 1 | `DEVELOPMENT_TEAM` захардкожен (2 разных team id) | `project.pbxproj` | Не критично для поста, критично для OSS |
| 2 | `NSAllowsArbitraryLoads = YES` | `project.pbxproj` | Не писать «maximum security» без оговорки |
| 3 | `VaulteDisplayName 2.swift` — дубликат имени | 2 копии в дереве | Убрать до публикации репо |
| 4 | `ApplicationViews.swift` — **7542 строки** | один файл | Не блокер поста, но слабое впечатление для dev-аудитории |
| 5 | README говорит «gold», в коде accent = **white** | `README.md` | Обновить перед постом про дизайн |
| 6 | Много hardcoded English в OTP / mode flows | `ApplicationViews.swift`, `ChatViewModel.swift` | Для международного поста — доработать |

---

## Средний приоритет

- Английский / немецкий / французский `.strings` — часть OTP-текста не локализована
- Качество звонков — были жалобы; не заявлять «studio quality»
- `.cursor/plans/` — не нужен в публичном репо
- Один commit `Initial Commit` при огромном diff — перед постом лучше нормальный history или squash с понятным message
- `OPEN_SOURCE_AUDIT.md` / `CONTRIBUTING.md` всё ещё пишут «gold» — синхронизировать с white theme

---

## Что **не** писать в посте (пока не исправлено)

- «Open source» → писать **source-available** или «код для аудита»
- «Секреты не в репозитории» → **ложь** на текущий момент
- «Полностью готово к App Store» → privacy email, секrets, ATS, signing не закрыты
- «E2E+» → режим удалён
- «Скопируйте наш OTP» → противоречит LICENSE

---

## Что **можно** писать честно

- Приватный мессенджер с E2E на устройстве
- Relay видит только ciphertext и метаданные маршрутизации
- One Time Pad — **настоящий** directional OTP, pads не на сервере
- OTP-реализация **не для копирования**, код публикуется для прозрачности
- Монохромный UI, typewriter-эстетика
- Privacy policy и технические материалы по E2E/OTP **внутри приложения**
- Нет рекламных SDK и analytics в этой версии

---

## Черновик поста (про приложение — можно сейчас)

> Vaulté Privé — приватный мессенджер для iOS.  
> Сообщения шифруются на устройстве до отправки. Сервер-реле видит только зашифрованные данные, не текст.  
>  
> Есть отдельный режим One Time Pad: pad-файлы обмениваются между вами и собеседником напрямую, не через сервер.  
>  
> Внутри — privacy policy, материалы по реализации E2E и OTP, safety numbers, исчезающие сообщения, звонки.  
>  
> Дизайн — чёрный фон, белый акцент, звёзды, AMTypewriter.  
>  
> Код готовится к source-available публикации для аудита. OTP нельзя копировать — это прописано в лицензии.

---

## Черновик поста (про код — только ПОСЛЕ фикса секретов)

> Мы выкладываем исходники Vaulté Privé для аудита.  
> Это не permissive open source: лицензия source-available, One Time Pad / Verified OTP нельзя переносить в другие продукты.  
>  
> В репозитории: iOS-клиент, relay-server, `docs/E2E-Implementation.md`, `docs/OTP-Implementation.md`, `PRIVACY_POLICY.md`.  
>  
> Relay-секреты не включены — поднимайте свой relay по `Secrets.example.xcconfig`.  
>  
> Если находите проблемы — пишите [ваш контакт].

---

## Чеклист «можно постить про код»

- [ ] Секреты удалены из `ChatAPIClient.swift` и `project.pbxproj`
- [ ] Секреты ротированы на Render
- [ ] `Messages 2/` убрана из публикуемого дерева
- [ ] Реальный privacy/support email
- [ ] README синхронизирован (white, не gold)
- [ ] `.gitignore` покрывает `Secrets.xcconfig`, `xcuserdata`, `node_modules`, `.build`
- [ ] LICENSE и PRIVACY_POLICY.md финальные
- [ ] Тестовый clone + build по README с нуля проходит
- [ ] Пост использует формулировку **source-available**, не «open source»

---

## Итог одной строкой

**Пост про продукт — можно.**  
**Пост про публикацию кода — нельзя, пока в репозитории лежат живые relay-секреты и мусор вроде `Messages 2/`.**
