# Бриф на иконку

Текущая иконка нарисована кодом (`scripts/make-icon.swift`) и честно помечена как заглушка: тёмный
сквиркл, синий контур чипа с ножками, три растущих столбика внутри. Идея верная, исполнение —
программистское. Ниже промт, по которому её можно перерисовать генератором, и что делать с
результатом.

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

## Что делать с результатом

Просить квадрат без скруглений: скругление — не декор, а системная форма, и её лучше наложить
самим, чем ловить чужой радиус. Дальше два пути:

- **Перенести в код.** Если генератор выдал что-то близкое к нынешней раскладке, дешевле поправить
  `scripts/make-icon.swift` — иконка останется воспроизводимой и ревьюабельной в диффе, а это и была
  причина рисовать её кодом.
- **Положить растр.** Тогда нужны все размеры из `AppIcon.appiconset` (16…1024, ×1 и ×2), а
  `make-icon.swift` уходит.

На macOS 26 иконки живут в Icon Composer со слоями и системной маской; классический `.appiconset`
по-прежнему работает и рисуется как есть. Пока цель — `LSMinimumSystemVersion 15.0`, менять формат
незачем.

См. также [DESIGN_BRIEF.md](DESIGN_BRIEF.md) — иконка это последний кусок интерфейса, который не
прошёл тот же заход, что панель.
