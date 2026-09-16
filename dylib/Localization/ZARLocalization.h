#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ZARLanguageChinese;
FOUNDATION_EXPORT NSString * const ZARLanguageVietnamese;
FOUNDATION_EXPORT NSString * const ZARLanguageEnglish;

/// Installs the single UIKit/NSBundle localization layer used by ZolaAntiRecall.
/// Safe to call more than once.
void ZARInstallLocalization(void);

/// Current UI language code: zh / vi / en.
NSString *ZARCurrentLanguage(void);

/// Change UI language and persist it in NSUserDefaults.
void ZARSetLanguage(NSString *language);

/// Translate a source string using the current language. Missing translations fall back to source.
NSString *ZARLocalizedString(NSString *source);

/// Human-readable language name in the current UI language.
NSString *ZARLanguageDisplayName(NSString *language);

NS_ASSUME_NONNULL_END
