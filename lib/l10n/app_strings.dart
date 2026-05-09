class AppStrings {
  final String languageCode;

  const AppStrings(this.languageCode);

  static AppStrings forLanguage(String? languageCode) {
    return AppStrings(languageCode == 'en' ? 'en' : 'pl');
  }

  bool get isEnglish => languageCode == 'en';

  String pick(String polish, String english) => isEnglish ? english : polish;
}
