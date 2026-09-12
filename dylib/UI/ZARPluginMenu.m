#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import "ZARPluginMenu.h"
#import "../Core/ZARLogger.h"
#import <objc/runtime.h>

static const NSInteger ZARPanelTag = 0x5A4152;
static NSString * const ZAREnabledKey = @"ZolaAntiRecallEnabled";

@interface ZARSwitchTarget : NSObject
+ (instancetype)shared;
- (void)valueChanged:(UISwitch *)sender;
@end

@interface ZARLogButtonTarget : NSObject
+ (instancetype)shared;
- (void)open:(UIButton *)sender;
@end

static BOOL ZAREnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:ZAREnabledKey] == nil) return YES;
    return [d boolForKey:ZAREnabledKey];
}

static void ZARSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:ZAREnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ZARLog(@"Plugin enabled=%@", enabled ? @"YES" : @"NO");
}

static NSArray<UIWindow *> *ZARAllWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateUnattached) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01 && window.bounds.size.width > 0) {
                    [result addObject:window];
                }
            }
        }
    } else {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (!window.hidden && window.alpha > 0.01 && window.bounds.size.width > 0) {
                [result addObject:window];
            }
        }
    }
    return result;
}

static UIView *ZARFindMenuView(UIView *root) {
    if (!root || root.hidden || root.alpha < 0.05) return nil;
    CGRect bounds = root.bounds;
    CGFloat bw = CGRectGetWidth(bounds);
    CGFloat bh = CGRectGetHeight(bounds);
    if (bw <= 0 || bh <= 0) return nil;

    for (UIView *v in [root.subviews reverseObjectEnumerator]) {
        if (v.hidden || v.alpha < 0.05 || v.tag == ZARPanelTag) continue;
        CGRect f = [v.superview convertRect:v.frame toView:root];
        CGFloat fw = CGRectGetWidth(f);
        CGFloat fh = CGRectGetHeight(f);
        CGFloat x = CGRectGetMinX(f);
        CGFloat y = CGRectGetMinY(f);

        BOOL plausible = fw >= bw * 0.55 && fw <= bw * 0.95 &&
                         fh >= 250 && fh <= bh * 0.55 &&
                         x >= 0 && x <= bw * 0.40 &&
                         y >= 0 && y <= bh * 0.35;
        if (plausible) return v;
        UIView *deeper = ZARFindMenuView(v);
        if (deeper) return deeper;
    }
    return nil;
}

static UIViewController *ZARTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindow *w in ZARAllWindows()) {
        if (w.isKeyWindow) { window = w; break; }
        if (!window) window = w;
    }
    if (!window) return nil;

    UIViewController *vc = window.rootViewController;
    while (vc) {
        UIViewController *next = vc.presentedViewController;
        if (next && !next.isBeingDismissed) { vc = next; continue; }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = [(UINavigationController *)vc visibleViewController];
            if (visible && visible != vc) { vc = visible; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = [(UITabBarController *)vc selectedViewController];
            if (selected && selected != vc) { vc = selected; continue; }
        }
        break;
    }
    return vc;
}

static void ZARShowLogViewer(UIViewController *presenting) {
    if (!presenting) return;
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) text = @"暂无日志。\n\n请先操作一次 + 菜单或进行 Recall 测试。";
    if (text.length > 16000) text = [text substringFromIndex:text.length - 16000];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ZolaAntiRecall 日志" message:nil preferredStyle:UIAlertControllerStyleAlert];
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.text = text;
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tv.layer.cornerRadius = 8;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.leadingAnchor constraintEqualToAnchor:alert.view.leadingAnchor constant:8],
        [tv.trailingAnchor constraintEqualToAnchor:alert.view.trailingAnchor constant:-8],
        [tv.topAnchor constraintEqualToAnchor:alert.view.topAnchor constant:55],
        [tv.heightAnchor constraintEqualToConstant:280]
    ]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [presenting presentViewController:alert animated:YES completion:nil];
}

static void ZARAddPanelToMenu(UIView *menu) {
    if (!menu || !menu.window || [menu viewWithTag:ZARPanelTag]) return;

    UIWindow *window = menu.window;
    CGRect menuRect = [menu.superview convertRect:menu.frame toView:window];
    CGFloat screenWidth = CGRectGetWidth(window.bounds);
    CGFloat screenHeight = CGRectGetHeight(window.bounds);
    CGFloat width = CGRectGetWidth(menuRect);
    CGFloat x = CGRectGetMinX(menuRect);
    CGFloat y = CGRectGetMaxY(menuRect) + 6;

    if (width < 180) return;
    width = MIN(width, screenWidth - x - 10);
    if (width < 180 || y + 92 > screenHeight) return;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, 92)];
    panel.tag = ZARPanelTag;
    panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 7, width - 82, 28)];
    title.text = @"ZolaAntiRecall";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    title.textColor = [UIColor labelColor];
    [panel addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, width - 82, 20)];
    sub.text = @"插件开关";
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = [UIColor secondaryLabelColor];
    [panel addSubview:sub];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.on = ZAREnabled();
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:[ZARSwitchTarget shared] action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [sw.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [sw.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor constant:-16]
    ]];

    UIButton *logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    logButton.frame = CGRectMake(12, 61, width - 24, 27);
    logButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [logButton setTitle:@"查看日志" forState:UIControlStateNormal];
    logButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [logButton addTarget:[ZARLogButtonTarget shared] action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:logButton];

    [window addSubview:panel];
    ZARLog(@"Plugin menu injected: %@ frame=%@", NSStringFromClass(menu.class), NSStringFromCGRect(menuRect));
}

@implementation ZARSwitchTarget
+ (instancetype)shared { static ZARSwitchTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)valueChanged:(UISwitch *)sender { ZARSetEnabled(sender.isOn); }
@end

@implementation ZARLogButtonTarget
+ (instancetype)shared { static ZARLogButtonTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)open:(UIButton *)sender { ZARShowLogViewer(ZARTopViewController()); }
@end

static void ZARScanAllWindowsAndInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ZARAllWindows()) {
            UIView *menu = ZARFindMenuView(window);
            if (menu) {
                ZARAddPanelToMenu(menu);
                return;
            }
        }
    });
}

@interface UIApplication (ZARPluginMenu)
- (BOOL)zar_sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event;
@end

@implementation UIApplication (ZARPluginMenu)
- (BOOL)zar_sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = [self zar_sendAction:action to:target from:sender forEvent:event];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZARScanAllWindowsAndInstall();
    });
    return result;
}
@end

void ZARInstallPluginMenuIfNeeded(void) {
    ZARScanAllWindowsAndInstall();
}

void ZARInstallPluginMenuHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method original = class_getInstanceMethod(UIApplication.class, @selector(sendAction:to:from:forEvent:));
        Method replacement = class_getInstanceMethod(UIApplication.class, @selector(zar_sendAction:to:from:forEvent:));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
            ZARLog(@"Plugin menu hook installed");
        } else {
            ZARLog(@"Plugin menu hook FAILED");
        }
    });

    // Zalo may present the + menu without routing through sendAction:
    // scan periodically for the first few seconds after injection.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSInteger i = 0; i < 30; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ZARScanAllWindowsAndInstall();
            });
        }
    });
}

#pragma clang diagnostic pop
