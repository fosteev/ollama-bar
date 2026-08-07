# Бриф на иконку

Иконка нарисована по этому промту и лежит в `design/icon.png`. До неё была заглушка, нарисованная
кодом в `scripts/make-icon.swift` — та же идея, но исполнение программистское. Ниже промт, по
которому её сделали, и что происходит с артворком дальше.

## Что иконка должна сказать

Одну вещь: **это измеритель, а не движок**. Приложение ничего не запускает и не ускоряет — оно
показывает, что происходит с чужим сервером. Отсюда пара «контейнер + показание»: чип как то, за чем
наблюдают, столбики как то, что намерили. Лама, облако, мозг и прочая LLM-иконография не подходят —
это иконка инструмента разработчика, а не продукта про ИИ.

Второе ограничение жёстче первого: иконка обязана читаться в 16 pt. В меню-баре живёт SF Symbol
`cpu`, и иконка приложения должна опознаваться как его родственник.

## Промт

> A macOS app icon for a developer utility that monitors a local LLM server from the menu bar.
>
> Subject: three vertical bars of rising height, sitting inside the outline of a processor die — a
> rounded square with three short pins along each of its four edges. The chip is the container, the
> bars are the live reading inside it.
>
> Style: flat vector, geometric, precise and even stroke weights, rounded joins. The drawing
> language of an SF Symbol rather than a startup logo. No text, no letters, no numbers.
>
> Background: a deep charcoal diagonal gradient, lighter at the top left, near-black at the bottom
> right, cool and slightly blue-shifted rather than neutral grey.
>
> Colour: exactly three. The chip outline and its pins in one confident blue (#5CA6FA), the bars in
> near-white (#F5F7FC), the background as described. Nothing else.
>
> Composition: subject centred on a square 1024×1024 canvas, background full bleed, about 26% clear
> margin between the chip and the canvas edge. Straight-on and flat — no perspective, no 3D, no
> bevel, no glass, no reflection, no drop shadow, no glow, no outer stroke.
>
> It has to survive being scaled to 16×16: nothing thinner than 3% of the canvas width, no detail
> beyond what is described above.

Негативный промт, если генератор его принимает:

> text, letters, numbers, watermark, llama, animal, cloud, brain, robot, gradient on the subject,
> photorealism, 3D render, bevel, emboss, glass, glossy highlight, reflection, drop shadow, outer
> glow, rounded canvas corners, border, frame, busy detail, multiple objects, perspective

## Что происходит с артворком

Промт просит квадрат без скруглений — и правильно делает: генераторы иконок отдают full-bleed
канвас по iOS-конвенции, а macOS иконки не маскирует. Скруглённый квадрат с отступом — часть самого
артворка, и иконка, которая этот шаг пропустила, стоит в доке жёстким квадратом на размер больше
соседей.

Поэтому источник остаётся плоским квадратом в `design/icon.png`, а форму накладывает
`scripts/make-icon.swift` по сетке Apple: тело 824 pt на канвасе 1024 pt, радиус угла 185.4. Он же
режет все размеры `AppIcon.appiconset` и переписывает `Contents.json`:

```bash
swift scripts/make-icon.swift
```

Держать в репозитории один PNG и скрипт, а не десять нарезанных растров, — это чтобы перерисовка
иконки оставалась диффом в одну строку и одну картинку.

В архиве от генератора лежал ещё `AppIcon.icon` — формат Icon Composer для macOS 26, со слоями,
стеклом и системной маской. Он не подключён: цель пока `LSMinimumSystemVersion 15.0`, классический
`.appiconset` там единственный рабочий вариант, и он же продолжает рисоваться как есть на 26.
Переезжать имеет смысл вместе с подъёмом минимальной версии.

См. также [DESIGN_BRIEF.md](DESIGN_BRIEF.md) — иконка это последний кусок интерфейса, который не
прошёл тот же заход, что панель.
