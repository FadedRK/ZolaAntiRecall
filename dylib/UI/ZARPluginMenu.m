#import "ZARPluginMenu.h"
#import "../Core/ZARLogger.h"
#import <objc/runtime.h>

static const NSInteger ZARPanelTag = 0x5A4152;
static const NSInteger ZARSwitchTag = 0x5A4153;
static NSString * const ZAREnabledKey = @"ZolaAntiRecallEnabled";

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
    for (UIView *v in root.subviews) {
        if (v.hidden || v.alpha < 0.05) continue;
        CGRect f = [v.superview convertRect:v.frame toView:root];
        CGFloat bw = CGRectGetWidth(bounds);
        CGFloat bh = CGRectGetHeight(bounds);
        BOOL plausible = CGRectGetWidth(f) >= bw * 0.45 && CGRectGetWidth(f) <= bw * 0.85 &&
                         CGRectGetHeight(f) >= 150 && CGRectGetHeight(f) <= bh * 0.45 &&
                         CGRectGetMinX(f) >= 5 && CGRectGetMinX(f) <= bw * 0.30 &&
                         CGRectGetMinY(f) >= 20 && CGRectGetMinY(f) <= bh * 0.25;
        if (plausible) {
            UIView *deeper = ZARFindMenuView(v);
            return deeper ?: v;
        }
        UIView *deeper = ZARFindMenuView(v);
        if (deeper) return deeper;
    }
    return nil;
}

static UIView *ZARTopMostMenu(UIView *root) {
    UIView *candidate = ZARFindMenuView(root);
    if (candidate) return candidate;
    for (UIView *v in [root.subviews reverseObjectEnumerator]) {
        UIView *candidate2 = ZARFindMenuView(v);
        if (candidate2) return candidate2;
    }
    return nil;
}

static void ZARShowLogViewer(UIViewController *presenting) {
    NSString *path = ZARLogPath();
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) text = @"暂无日志。\n\n请先重启 Zalo，然后操作一次 + 菜单或进行测试。";
    if (text.length > 12000) text = [text substringFromIndex:text.length - 12000];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ZolaAntiRecall 日志"
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleAlert];
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.text = text;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
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

static UIViewController *ZARTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) { window = w; break; }
        if (!window) window = w;
    }
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

static void ZARAddPanelToMenu(UIView *menu, UIViewController *vc) {
    if (!menu || !vc) return;
    if ([menu viewWithTag:ZARPanelTag]) return;

    UIWindow *window = menu.window;
    if (!window) return;
    CGRect menuRect = [menu.superview convertRect:menu.frame toView:window];
    CGFloat width = CGRectGetWidth(menuRect);
    CGFloat x = CGRectGetMinX(menuRect);
    CGFloat y = CGRectGetMaxY(menuRect) + 6;
    if (width < 180) width = 220;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, 92)];
    panel.tag = ZARPanelTag;
    panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, width - 90, 34)];
    title.text = @"ZolaAntiRecall";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    title.textColor = [UIColor labelColor];
    [panel addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, width - 90, 28)];
    sub.text = @"插件开关";
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = [UIColor secondaryLabelColor];
    [panel addSubview:sub];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.tag = ZARSwitchTag;
    sw.on = ZAREnabled();
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:[ZARSwitchTarget shared] action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [sw.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [sw.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor constant:-15]
    ]];

    UIButton *logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    logButton.frame = CGRectMake(12, 67, width - 24, 25);
    logButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [logButton setTitle:@"查看日志" forState:UIControlStateNormal];
    logButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [logButton addTarget:[ZARLogButtonTarget shared] action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:logButton];

    [window addSubview:panel];
    ZARLog(@"Plugin menu injected into + menu");
}

@interface ZARSwitchTarget : NSObject
+ (instancetype)shared;
- (void)valueChanged:(UISwitch *)sender;
@end
@implementation ZARSwitchTarget
+ (instancetype)shared { static ZARSwitchTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)valueChanged:(UISwitch *)sender { ZARSetEnabled(sender.isOn); }
@end

@interface ZARLogButtonTarget : NSObject
+ (instancetype)shared;
- (void)open:(UIButton *)sender;
@end
@implementation ZARLogButtonTarget
+ (instancetype)shared { static ZARLogButtonTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)open:(UIButton *)sender { UIViewController *vc=ZARTopViewController(); if (vc) ZARShowLogViewer(vc); }
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
            if (topRight) {
                dispatch_async(dispatch_get_main_queue(), ^{ ZARInstallPluginMenuIfNeeded(); });
            }
        }
    }
    return result;
}
@end

void ZARInstallPluginMenuIfNeeded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.hidden && w.alpha > 0.01 && w.isKeyWindow) { window = w; break; }
        }
        if (!window) return;
        UIView *menu = ZARTopMostMenu(window);
        if (!menu) return;
        UIViewController *vc = ZARTopViewController();
        ZARAddPanelToMenu(menu, vc);
    });
}

void ZARInstallPluginMenuHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method m = class_getInstanceMethod(UIApplication.class, @selector(sendAction:to:from:forEvent:));
        Method sw = class_getInstanceMethod(UIApplication.class, @selector(zar_sendAction:to:from:forEvent:));
        if (m && sw) method_exchangeImplementations(m, sw);
        ZARLog(@"Plugin menu hook installed");
    });
}
