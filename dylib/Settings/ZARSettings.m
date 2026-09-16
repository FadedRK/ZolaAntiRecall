#import "ZARSettings.h"
#import "../Core/ZARLogger.h"
#import "../Diagnostics/ZARMessageTrace.h"
#import "../Localization/ZARLocalization.h"
#import <objc/runtime.h>

static NSString * const ZAREnabledKey = @"ZolaAntiRecallEnabled";
static NSString * const ZARShowMyRecallKey = @"ZolaAntiRecallShowMyRecall";
static NSInteger const ZARSettingsEntryTag = 0x5A415253;

static NSString *ZARSettingText(NSString *zh, NSString *vi, NSString *en) {
    NSString *lang = ZARCurrentLanguage();
    if ([lang isEqualToString:@"vi"]) return vi;
    if ([lang isEqualToString:@"en"]) return en;
    return zh;
}

@implementation ZARSettings

+ (instancetype)sharedInstance {
    static ZARSettings *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [ZARSettings new]; });
    return instance;
}

- (BOOL)showMyRecallEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:ZARShowMyRecallKey] == nil) return YES;
    return [defaults boolForKey:ZARShowMyRecallKey];
}

- (void)setShowMyRecallEnabled:(BOOL)enabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:ZARShowMyRecallKey];
    [defaults synchronize];
    ZARLog(@"Show my recall enabled=%@", enabled ? @"YES" : @"NO");
}

@end

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
    UISwitch *_myRecallSwitch;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52.0;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self refreshTexts];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshTexts];
    [self.tableView reloadData];
}

- (void)refreshTexts {
    self.title = @"ZolaAntiRecall";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : 2; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? ZARSettingText(@"基础", @"Cơ bản", @"Basic") : ZARSettingText(@"诊断", @"Chẩn đoán", @"Diagnostics");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return ZARSettingText(@"插件总开关关闭后，本插件不执行后续功能。自己撤回消息开关仅控制“你已撤回”是否保留。", @"Khi tắt công tắc chính, plugin sẽ không thực hiện chức năng. Công tắc tin nhắn bạn thu hồi chỉ kiểm soát việc giữ lại nội dung đã thu hồi.", @"When the master switch is off, the plugin does not run. The self-recall switch only controls whether your recalled messages are preserved.");
    return ZARSettingText(@"运行时扫描用于定位 Zalo 的 Recall 相关 Class / Method。", @"Quét runtime dùng để xác định Class / Method liên quan đến Recall của Zalo.", @"The runtime scanner locates Zalo Recall-related classes and methods.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZARSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = ZARSettingText(@"插件总开关", @"Công tắc plugin", @"Plugin Enabled");
        UISwitch *sw = [UISwitch new];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        sw.on = [defaults objectForKey:ZAREnabledKey] ? [defaults boolForKey:ZAREnabledKey] : YES;
        [sw addTarget:self action:@selector(pluginSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw; _pluginSwitch = sw;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = ZARSettingText(@"显示自己撤回的消息", @"Hiển thị tin nhắn bạn đã thu hồi", @"Show My Recalled Messages");
        UISwitch *sw = [UISwitch new];
        sw.on = [ZARSettings sharedInstance].showMyRecallEnabled;
        [sw addTarget:self action:@selector(myRecallSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw; _myRecallSwitch = sw;
    } else if (indexPath.section == 0 && indexPath.row == 2) {
        cell.textLabel.text = ZARSettingText(@"界面语言", @"Ngôn ngữ giao diện", @"Interface Language");
        cell.detailTextLabel.text = ZARLanguageDisplayName(ZARCurrentLanguage());
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.row == 0) {
        cell.textLabel.text = ZARSettingText(@"Recall 运行时扫描器", @"Trình quét Recall Runtime", @"Recall Runtime Scanner");
        cell.detailTextLabel.text = ZARSettingText(@"扫描 Class / Method", @"Quét Class / Method", @"Scan Class / Method");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = ZARSettingText(@"日志文件", @"Tệp nhật ký", @"Log File");
        cell.detailTextLabel.text = ZARSettingText(@"查看当前日志路径", @"Xem đường dẫn nhật ký", @"View current log path");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)pluginSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:ZAREnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ZARLog(@"Plugin enabled=%@", sender.isOn ? @"YES" : @"NO");
}

- (void)myRecallSwitchChanged:(UISwitch *)sender { [ZARSettings sharedInstance].showMyRecallEnabled = sender.isOn; }

- (void)chooseLanguage {
    NSString *title = ZARSettingText(@"界面语言", @"Ngôn ngữ giao diện", @"Interface Language");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *codes = @[@"zh", @"vi", @"en"];
    for (NSString *code in codes) {
        NSString *name = ZARLanguageDisplayName(code);
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            ZARSetLanguage(code);
            [self refreshTexts];
            [self.tableView reloadData];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:ZARSettingText(@"取消", @"Hủy", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 2) { [self chooseLanguage]; return; }
    if (indexPath.section == 1 && indexPath.row == 0) {
        [self.navigationController pushViewController:[ZARDiagnosticViewController new] animated:YES];
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        NSString *path = ZARLogPath();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:ZARSettingText(@"日志文件", @"Tệp nhật ký", @"Log File") message:path preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ZARSettingText(@"确定", @"OK", @"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

@implementation ZARDiagnosticViewController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = ZARSettingText(@"Recall 扫描器", @"Trình quét Recall", @"Recall Scanner");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO; _textView.selectable = YES;
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
    UIBarButtonItem *rescan = [[UIBarButtonItem alloc] initWithTitle:ZARSettingText(@"重新扫描", @"Quét lại", @"Rescan") style:UIBarButtonItemStylePlain target:self action:@selector(rescan)];
    UIBarButtonItem *export = [[UIBarButtonItem alloc] initWithTitle:ZARSettingText(@"导出日志", @"Xuất nhật ký", @"Export Log") style:UIBarButtonItemStylePlain target:self action:@selector(exportLog)];
    self.navigationItem.rightBarButtonItems = @[export, rescan];
    [self refreshText];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshText]; }
- (void)refreshText { _textView.text = [NSString stringWithFormat:@"%@\n\n%@：%@", ZARDiagnosticText() ?: ZARSettingText(@"暂无扫描结果", @"Chưa có kết quả quét", @"No scan result"), ZARSettingText(@"日志文件", @"Tệp nhật ký", @"Log file"), ZARLogPath()]; }

- (void)rescan {
    self.navigationItem.rightBarButtonItems.lastObject.enabled = NO;
    _textView.text = ZARSettingText(@"正在扫描运行时 Class / Method，请稍候…", @"Đang quét Class / Method runtime, vui lòng chờ…", @"Scanning runtime Class / Method, please wait…");
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
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) ZARRunMessageTrace();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:ZARSettingText(@"暂无日志", @"Chưa có nhật ký", @"No Log") message:ZARSettingText(@"请先点击“重新扫描”。", @"Vui lòng bấm “Quét lại” trước.", @"Please tap “Rescan” first.") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil]; return;
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
    NSMutableArray *newItems = [items mutableCopy]; [newItems addObject:item];
    vc.navigationItem.rightBarButtonItems = newItems;
    ZARLog(@"Settings entry installed on %@", NSStringFromClass(vc.class));
}

@implementation ZARSettingsEntryTarget
+ (instancetype)shared { static ZARSettingsEntryTarget *target; static dispatch_once_t once; dispatch_once(&once, ^{ target = [ZARSettingsEntryTarget new]; }); return target; }
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
