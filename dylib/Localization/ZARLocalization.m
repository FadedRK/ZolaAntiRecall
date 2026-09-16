#import "ZARLocalization.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;

NSString * const ZARLanguageChinese = @"zh";
NSString * const ZARLanguageVietnamese = @"vi";
NSString * const ZARLanguageEnglish = @"en";

static NSString * const ZARLanguageKey = @"ZolaAntiRecallLanguage";
static NSDictionary *ZARTranslations;
static BOOL ZARLocalizationInstalled = NO;
static NSUInteger ZARLocalizationHitCount = 0;

static BOOL ZARValidString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    if ([s isEqualToString:@"<null>"] || [s isEqualToString:@"<Not Found>"]) return NO;
    return YES;
}

static void ZARLoadTranslations(void) {
    NSData *data = [NSData dataWithBytes:ZLCNTranslationsPlist length:ZLCNTranslationsPlistLength];
    NSError *error = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    ZARTranslations = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
    NSLog(@"[ZAR-L10N] loaded %lu translation entries%@", (unsigned long)ZARTranslations.count,
          error ? [NSString stringWithFormat:@"; parse error=%@", error] : @"");
}

NSString *ZARCurrentLanguage(void) {
    NSString *language = [[NSUserDefaults standardUserDefaults] stringForKey:ZARLanguageKey];
    if ([language isEqualToString:ZARLanguageVietnamese] || [language isEqualToString:ZARLanguageEnglish]) return language;
    return ZARLanguageChinese;
}

void ZARSetLanguage(NSString *language) {
    if (![language isEqualToString:ZARLanguageVietnamese] && ![language isEqualToString:ZARLanguageEnglish]) language = ZARLanguageChinese;
    [[NSUserDefaults standardUserDefaults] setObject:language forKey:ZARLanguageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ZAR-L10N] language=%@", language);
}

NSString *ZARLocalizedString(NSString *source) {
    if (!ZARValidString(source) || ZARTranslations.count == 0) return source;
    id entry = ZARTranslations[source];
    if (!entry) {
        NSString *trimmed = [source stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!ZARValidString(trimmed)) return source;
        entry = ZARTranslations[trimmed];
    }
    if (![entry isKindOfClass:[NSDictionary class]]) return source;

    NSString *language = ZARCurrentLanguage();
    NSString *translated = entry[language];
    if (!ZARValidString(translated)) translated = entry[ZARLanguageChinese];
    if (!ZARValidString(translated)) translated = source;

    if (![translated isEqualToString:source] && ++ZARLocalizationHitCount <= 100)
        NSLog(@"[ZAR-L10N] %@ -> %@ (%@)", source, translated, language);
    return translated;
}

NSString *ZARLanguageDisplayName(NSString *language) {
    NSString *ui = ZARCurrentLanguage();
    if ([ui isEqualToString:ZARLanguageVietnamese]) {
        if ([language isEqualToString:ZARLanguageVietnamese]) return @"Tiếng Việt";
        if ([language isEqualToString:ZARLanguageEnglish]) return @"English";
        return @"Tiếng Trung";
    }
    if ([ui isEqualToString:ZARLanguageEnglish]) {
        if ([language isEqualToString:ZARLanguageVietnamese]) return @"Vietnamese";
        if ([language isEqualToString:ZARLanguageEnglish]) return @"English";
        return @"Chinese";
    }
    if ([language isEqualToString:ZARLanguageVietnamese]) return @"Tiếng Việt";
    if ([language isEqualToString:ZARLanguageEnglish]) return @"English";
    return @"中文";
}

static void ZARSwizzle(Class cls, SEL selector, IMP replacement, SEL alias) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    if (!class_getInstanceMethod(cls, alias)) {
        class_addMethod(cls, alias, method_getImplementation(method), method_getTypeEncoding(method));
        method_setImplementation(method, replacement);
    }
}

static id ZARBundleLocalizedString(NSBundle *self, SEL cmd, NSString *key, NSString *value, NSString *table) {
    SEL alias = sel_registerName("zar_l10n_orig_bundle_localizedStringForKey:value:table:");
    id (*orig)(id, SEL, NSString *, NSString *, NSString *) = (id (*)(id, SEL, NSString *, NSString *, NSString *))[self methodForSelector:alias];
    NSString *result = orig ? orig(self, alias, key, value, table) : (value ?: key);
    return ZARLocalizedString(result);
}

static void ZARLabelSetText(UILabel *self, SEL cmd, NSString *text) {
    SEL alias = sel_registerName("zar_l10n_orig_label_setText:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(text));
}

static void ZARButtonSetTitle(UIButton *self, SEL cmd, NSString *title, UIControlState state) {
    SEL alias = sel_registerName("zar_l10n_orig_button_setTitle:forState:");
    void (*orig)(id, SEL, NSString *, UIControlState) = (void (*)(id, SEL, NSString *, UIControlState))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(title), state);
}

static void ZARBarSetTitle(UIBarButtonItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zar_l10n_orig_bar_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(title));
}

static void ZARNavigationSetTitle(UINavigationItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zar_l10n_orig_nav_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(title));
}

static void ZARTabSetTitle(UITabBarItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zar_l10n_orig_tab_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(title));
}

static void ZARSearchSetPlaceholder(UISearchBar *self, SEL cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zar_l10n_orig_search_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(placeholder));
}

static void ZARFieldSetPlaceholder(UITextField *self, SEL cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zar_l10n_orig_field_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZARLocalizedString(placeholder));
}

void ZARInstallLocalization(void) {
    if (ZARLocalizationInstalled) return;
    ZARLocalizationInstalled = YES;
    ZARLoadTranslations();
    ZARSwizzle(NSBundle.class, @selector(localizedStringForKey:value:table:), (IMP)ZARBundleLocalizedString, sel_registerName("zar_l10n_orig_bundle_localizedStringForKey:value:table:"));
    ZARSwizzle(UILabel.class, @selector(setText:), (IMP)ZARLabelSetText, sel_registerName("zar_l10n_orig_label_setText:"));
    ZARSwizzle(UIButton.class, @selector(setTitle:forState:), (IMP)ZARButtonSetTitle, sel_registerName("zar_l10n_orig_button_setTitle:forState:"));
    ZARSwizzle(UIBarButtonItem.class, @selector(setTitle:), (IMP)ZARBarSetTitle, sel_registerName("zar_l10n_orig_bar_setTitle:"));
    ZARSwizzle(UINavigationItem.class, @selector(setTitle:), (IMP)ZARNavigationSetTitle, sel_registerName("zar_l10n_orig_nav_setTitle:"));
    ZARSwizzle(UITabBarItem.class, @selector(setTitle:), (IMP)ZARTabSetTitle, sel_registerName("zar_l10n_orig_tab_setTitle:"));
    ZARSwizzle(UISearchBar.class, @selector(setPlaceholder:), (IMP)ZARSearchSetPlaceholder, sel_registerName("zar_l10n_orig_search_setPlaceholder:"));
    ZARSwizzle(UITextField.class, @selector(setPlaceholder:), (IMP)ZARFieldSetPlaceholder, sel_registerName("zar_l10n_orig_field_setPlaceholder:"));
    NSLog(@"[ZAR-L10N] installed; language=%@", ZARCurrentLanguage());
}
