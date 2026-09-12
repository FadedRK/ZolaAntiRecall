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

static UIView *ZARFindMenuView(UIView *root) {
    CGRect bounds = root.bounds;
    CGFloat bw = CGRectGetWidth(bounds);
    CGFloat bh = CGRectGetHeight(bounds);
    if (bw <= 0 || bh <= 0) return nil;

    for (UIView *v in [root.subviews reverseObjectEnumerator]) {
        if (v.hidden || v.alpha < 0.05 || v.tag == ZARPanelTag) continue;
        CGRect f = [v.superview convertRect:v.frame toView:root];
        BOOL plausible = CGRectGetWidth(f) >= bw * 0.45 &&
                         CGRectGetWidth(f) <= bw * 0.90 &&
                         CGRectGetHeight(f) >= 150 &&
                         CGRectGetHeight(f) <= bh * 0.45 &&
                         CGRectGetMinX(f) >= 5 &&
                         CGRectGetMinX(f) <= bw * 0.35 &&
                         CGRectGetMinY(f) >= 20 &&
                         CGRectGetMinY(f) <= bh * 0.28;
        if (plausible) return v;
        UIView *deeper = ZARFindMenuView(v);
        if (deeper) return deeper;
    }
    return nil;
}

static UIViewController *ZARTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) { window = w; break; }
        if (!window) window = w;
    }
    if (!window) return nil;
    UIViewController *vc = window.rootViewController;
    while (vc) {
        UIViewController *next = vc.presentedViewController;
        if (next && !next.isBeingDismissed) { vc = next; continue; }
        if ([vc isKindOfClass:[UINavigationController class]]) { vc = [(UINavigationController *)vc visibleViewController]; continue; }
        if ([vc isKindOfClass:[UITabBarController class]]) { vc = [(UITabBarController *)vc selectedViewController]; continue; }
        break;
    }
    return vc;
}

static void ZARShowLogViewer(UIViewController *presenting) {
    if (!presenting) return;
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) text = @"暂无日志。\n\n请先重启 Zalo，然后操作一次 + 菜单或进行测试。";
    if (text.length > 12000) text = [text substringFromIndex:text.length - 12000];

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
        [tv.heightAnchor constraintEqualToConstant:260]
    ]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [presenting presentViewController:alert animated:YES completion:nil];
}

static void ZARAddPanelToMenu(UIView *menu) {
    if (!menu || !menu.window || [menu viewWithTag:ZARPanelTag]) return;

    UIWindow *window = menu.window;
    CGRect menuRect = [menu.superview convertRect:menu.frame toView:window];
    CGFloat width = CGRectGetWidth(menuRect);
    if (width < 180) return;
    CGFloat x = CGRectGetMinX(menuRect);
    CGFloat y = CGRectGetMaxY(menuRect) + 6;
    CGFloat maxWidth = CGRectGetWidth(window.bounds) - x - 10;
    width = MIN(width, maxWidth);

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
    ZARLog(@"Plugin menu injected into + menu");
}

@implementation ZARSwitchTarget
+ (instancetype)shared { static ZARSwitchTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)valueChanged:(UISwitch *)sender { ZARSetEnabled(sender.isOn); }
@end

@implementation ZARLogButtonTarget
+ (instancetype)shared { static ZARLogButtonTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)open:(UIButton *)sender { ZARShowLogViewer(ZARTopViewController()); }
@end

@interface UIApplication (ZARPluginMenu)
- (BOOL)zar_sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event;
@end

@implementation UIApplication (ZARPluginMenu)
- (BOOL)zar_sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = [self zar_sendAction:action to:target from:sender forEvent:event];
    if ([sender isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)sender;
        UIWindow *window = button.window;
        if (window) {
            CGRect f = [button.superview convertRect:button.frame toView:window];
            CGSize s = window.bounds.size;
            BOOL topRight = CGRectGetMidX(f) > s.width * 0.78 && CGRectGetMidY(f) < s.height * 0.16;
            if (topRight) dispatch_async(dispatch_get_main_queue(), ^{ ZARInstallPluginMenuIfNeeded(); });
        }
    }
    return result;
}
@end

void ZARInstallPluginMenuIfNeeded(void) {
    UIWindow *window = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.hidden && w.alpha > 0.01 && w.isKeyWindow) { window = w; break; }
    }
    if (!window) return;
    UIView *menu = ZARFindMenuView(window);
    if (menu) ZARAddPanelToMenu(menu);
}

void ZARInstallPluginMenuHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method original = class_getInstanceMethod(UIApplication.class, @selector(sendAction:to:from:forEvent:));
        Method replacement = class_getInstanceMethod(UIApplication.class, @selector(zar_sendAction:to:from:forEvent:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
        ZARLog(@"Plugin menu hook installed");
    });
}
