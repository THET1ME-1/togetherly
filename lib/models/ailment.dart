import '../services/locale_service.dart';

/// Один пункт каталога недомоганий («болячки»).
/// Лейблы хранятся прямо здесь (ru/en) — отдельных строк в LocaleService на
/// каждую болячку не заводим; [localizedLabel] выбирает язык на лету.
class Ailment {
  final String id;
  final String emoji;
  final String ru;
  final String en;

  const Ailment(this.id, this.emoji, this.ru, this.en);

  String get localizedLabel =>
      LocaleService.instance.isRussian ? ru : en;
}

/// Каталог недомоганий. Порядок = порядок отображения в пикере.
const List<Ailment> kAilments = [
  Ailment('unwell', '🤒', 'Нездоровится', 'Unwell'),
  Ailment('headache', '🤕', 'Голова болит', 'Headache'),
  Ailment('heartburn', '🔥', 'Изжога', 'Heartburn'),
  Ailment('nausea', '🤢', 'Тошнит', 'Nausea'),
  Ailment('cold', '🤧', 'Простуда', 'Cold'),
  Ailment('fever', '🌡️', 'Температура', 'Fever'),
  Ailment('stomach', '😣', 'Живот болит', 'Stomachache'),
  Ailment('throat', '😷', 'Горло болит', 'Sore throat'),
  Ailment('cough', '🫁', 'Кашель', 'Cough'),
  Ailment('tooth', '🦷', 'Зуб болит', 'Toothache'),
  Ailment('back', '🦴', 'Спина болит', 'Back pain'),
  Ailment('cramps', '💢', 'Спазмы', 'Cramps'),
  Ailment('dizzy', '😵‍💫', 'Кружится голова', 'Dizzy'),
  Ailment('fatigue', '😴', 'Усталость', 'Tired'),
  Ailment('insomnia', '🌙', 'Бессонница', 'Insomnia'),
  Ailment('allergy', '🌿', 'Аллергия', 'Allergy'),
];

/// Найти болячку по id (для восстановления выбора из сохранённого статуса).
Ailment? ailmentById(String id) {
  for (final a in kAilments) {
    if (a.id == id) return a;
  }
  return null;
}
