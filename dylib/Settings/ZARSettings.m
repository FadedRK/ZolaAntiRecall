#import "ZARSettings.h"
#import "../Core/ZARLogger.h"
#import "../Diagnostics/ZARMessageTrace.h"
#import <objc/runtime.h>

static NSString * const ZAREnabledKey = @"ZolaAntiRecallEnabled";
static NSInteger const ZARSettingsEntryTag = 0x5A415253;

@interface ZARSettingsViewController : UITableViewController
@end

@interface ZARSettingsEntryTarget : NSObject
+ (instancetype)shared;
- (void)open;
@end

@interface ZARDiagnosticViewController : UIViewController
@end

@implementation ZARSettingsViewController {
    UISwitch *_pluginSwitch;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ZolaAntiRecall";
    self.tableView.rowHeight = 52.0;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"基础" : @"诊断";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"插件总开关关闭后，本插件不执行任何后续功能。" : @"运行时扫描仅用于定位 Zalo 的 Recall 相关 Class / Method，不修改目标方法。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZARSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == 0) {
        cell.textLabel.text = @"插件总开关";
        UISwitch *sw = [UISwitch new];
        sw.on = [[NSUserDefaults standardUserDefaults] objectForKey:ZAREnabledKey] ? [[NSUserDefaults standardUserDefaults] boolForKey:ZAREnabledKey] : YES;
        [sw addTarget:self action:@selector(pluginSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        _pluginSwitch = sw;
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Recall 运行时扫描器";
        cell.detailTextLabel.text = @"扫描 Class / Method";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"日志文件";
        cell.detailTextLabel.text = @"查看当前日志路径";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)pluginSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:ZAREnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ZARLog(@"Plugin enabled=%@", sender.isOn ? @"YES" : @"NO");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) {
        ZARDiagnosticViewController *vc = [ZARDiagnosticViewController new];
        [self.navigationController pushViewController:vc animated:YES];
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        NSString *path = ZARLogPath();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"日志文件" message:path preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

@implementation ZARDiagnosticViewController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recall 扫描器";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    _textView.textColor = [UIColor labelColor];
    _textView.backgroundColor = [UIColor systemBackgroundColor];
    _textView.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
    [self.view addSubview:_textView];
    [NSLayoutConstraint activateConstraints:@[
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIBarButtonItem *rescan = [[UIBarButtonItem alloc] initWithTitle:@"重新扫描" style:UIBarButtonItemStylePlain target:self action:@selector(rescan)];
    UIBarButtonItem *export = [[UIBarButtonItem alloc] initWithTitle:@"导出日志" style:UIBarButtonItemStylePlain target:self action:@selector(exportLog)];
    self.navigationItem.rightBarButtonItems = @[export, rescan];
    [self refreshText];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshText];
}

- (void)refreshText {
    NSString *text = ZARDiagnosticText();
    _textView.text = [NSString stringWithFormat:@"%@\n\n日志文件：%@", text ?: @"暂无扫描结果", ZARLogPath()];
}

- (void)rescan {
    self.navigationItem.rightBarButtonItems.lastObject.enabled = NO;
    _textView.text = @"正在扫描运行时 Class / Method，请稍候…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ZARRunMessageTrace();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.rightBarButtonItems.lastObject.enabled = YES;
            [self refreshText];
        });
    });
}

- (void)exportLog {
    NSString *path = ZARLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        ZARRunMessageTrace();
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无日志" message:@"请先点击“重新扫描”。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    if (activity.popoverPresentationController) activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:activity animated:YES completion:nil];
}

@end

static UIViewController *ZARTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { keyWindow = window; break; }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) return nil;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    while ([vc isKindOfClass:[UITabBarController class]] && ((UITabBarController *)vc).selectedViewController) vc = ((UITabBarController *)vc).selectedViewController;
    while ([vc isKindOfClass:[UINavigationController class]] && ((UINavigationController *)vc).visibleViewController) vc = ((UINavigationController *)vc).visibleViewController;
    return vc;
}

static BOOL ZARLooksLikeSettings(UIViewController *vc) {
    if (!vc) return NO;
    NSString *className = NSStringFromClass(vc.class).lowercaseString;
    NSString *title = (vc.navigationItem.title ?: vc.title).lowercaseString;
    return [className containsString:@"setting"] || [title isEqualToString:@"cài đặt"] || [title isEqualToString:@"设置"] || [title isEqualToString:@"settings"];
}

static void ZARConfigureSettingsEntry(UIViewController *vc) {
    if (!ZARLooksLikeSettings(vc)) return;
    NSArray<UIBarButtonItem *> *items = vc.navigationItem.rightBarButtonItems ?: @[];
    for (UIBarButtonItem *item in items) if (item.tag == ZARSettingsEntryTag) return;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"ZolaAntiRecall" style:UIBarButtonItemStylePlain target:[ZARSettingsEntryTarget shared] action:@selector(open)];
    item.tag = ZARSettingsEntryTag;
    NSMutableArray *newItems = [items mutableCopy];
    [newItems addObject:item];
    vc.navigationItem.rightBarButtonItems = newItems;
    ZARLog(@"Settings entry installed on %@", NSStringFromClass(vc.class));
}

@implementation ZARSettingsEntryTarget
+ (instancetype)shared {
    static ZARSettingsEntryTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [ZARSettingsEntryTarget new]; });
    return target;
}
- (void)open {
    UIViewController *source = ZARTopViewController();
    if (!source) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ZARSettingsViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [source presentViewController:nav animated:YES completion:nil];
}
@end

static void ZARSettingsViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    SEL alias = sel_registerName("zar_orig_viewDidAppear:");
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, animated);
    dispatch_async(dispatch_get_main_queue(), ^{ ZARConfigureSettingsEntry(self); });
}

void ZARInstallSettings(void) {
    Class cls = [UIViewController class];
    Method method = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!method) return;
    SEL alias = sel_registerName("zar_orig_viewDidAppear:");
    if (!class_getInstanceMethod(cls, alias)) {
        class_addMethod(cls, alias, method_getImplementation(method), method_getTypeEncoding(method));
        method_setImplementation(method, (IMP)ZARSettingsViewDidAppear);
        ZARLog(@"Settings hook installed");
    }
}
