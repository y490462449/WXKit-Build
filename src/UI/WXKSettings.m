#import "WXKSettings.h"
#import "WXKCommon.h"
#import "WXKPrefs.h"
#import "WXKHook.h"
#import "WXKLog.h"
#import "WXKBridge.h"
#import "WXKMsgStore.h"
#import "WXKAI.h"
#import "WXKDiagnostics.h"
#import "WXKSelfTest.h"
#import "WXKOverrides.h"
#import "WXKFloating.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 行模型

typedef NS_ENUM(NSInteger, WXKRowKind) {
    WXKRowKindSwitch,
    WXKRowKindText,      // 点击进入编辑
    WXKRowKindNumber,
    WXKRowKindAction,
    WXKRowKindInfo,
};

@interface WXKRow : NSObject
@property (nonatomic, assign) WXKRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) BOOL secure;
@property (nonatomic, assign) BOOL multiline;
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)row:(WXKRowKind)kind title:(NSString *)title key:(NSString *)key;
@end

@implementation WXKRow
+ (instancetype)row:(WXKRowKind)kind title:(NSString *)title key:(NSString *)key {
    WXKRow *r = [[WXKRow alloc] init];
    r.kind = kind;
    r.title = title;
    r.key = key;
    return r;
}
@end

static UIViewController *WXKTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc topViewController];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = [(UITabBarController *)vc selectedViewController];
    }
    return vc;
}

#pragma mark - 只读文本页

@interface WXKTextPageViewController : UIViewController
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, copy) NSString *body;
@end

// 私有方法显式声明，避免"方法定义在后面"带来的编译期不确定性
@interface WXKTextPageViewController ()
- (void)close;
- (void)share;
@end

@implementation WXKTextPageViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pageTitle;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self
                                                      action:@selector(share)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(close)];

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    textView.text = self.body;
    [self.view addSubview:textView];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)share {
    NSString *path = [WXKDiagnostics writeText:self.body fileName:@"wxkit-share.txt"];
    NSMutableArray *items = [NSMutableArray arrayWithObject:self.body];
    if (path) [items addObject:[NSURL fileURLWithPath:path]];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                            applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}
@end

#pragma mark - 值编辑器

@interface WXKValueEditorViewController : UIViewController
@property (nonatomic, copy) NSString *rowTitle;
@property (nonatomic, copy) NSString *rowKey;
@property (nonatomic, assign) WXKRowKind kind;
@property (nonatomic, assign) BOOL secure;
@property (nonatomic, assign) BOOL multiline;
@end

@interface WXKValueEditorViewController ()
- (void)close;
- (void)save;
@end

@implementation WXKValueEditorViewController {
    UITextField *_field;
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.rowTitle;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(close)];

    NSString *current = [[WXKPrefs shared] stringForKey:self.rowKey] ?: @"";
    CGRect frame = CGRectInset(self.view.bounds, 16, 16);
    if (self.multiline) {
        _textView = [[UITextView alloc] initWithFrame:frame];
        _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _textView.font = [UIFont systemFontOfSize:14];
        _textView.text = current;
        _textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
        _textView.layer.cornerRadius = 8;
        [self.view addSubview:_textView];
    } else {
        _field = [[UITextField alloc] initWithFrame:CGRectMake(16, 20, frame.size.width, 44)];
        _field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _field.borderStyle = UITextBorderStyleRoundedRect;
        _field.font = [UIFont systemFontOfSize:14];
        _field.secureTextEntry = self.secure;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.keyboardType = self.kind == WXKRowKindNumber ? UIKeyboardTypeNumbersAndPunctuation
                                                           : UIKeyboardTypeDefault;
        _field.placeholder = current.length ? nil : @"请输入";
        _field.text = current;
        [self.view addSubview:_field];
        [_field becomeFirstResponder];
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)save {
    NSString *value = self.multiline ? _textView.text : _field.text;
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if ([self.rowKey isEqualToString:WXKKeyOverrideText]) {
        // 候选名覆盖要校验后再存（applyText 内部会保存）
        NSString *error = nil;
        if (![WXKOverrides applyText:value error:&error]) {
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"这段文本没能识别"
                                                    message:error
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;   // 不关闭，方便继续改
        }
        WXKLog(@"[override] 覆盖已保存");
        [self close];
        return;
    }
    if (self.kind == WXKRowKindNumber) {
        [[WXKPrefs shared] setDouble:value.doubleValue forKey:self.rowKey];
    } else {
        [[WXKPrefs shared] setObject:value forKey:self.rowKey];
    }
    WXKLog(@"[prefs] 更新 %@", self.rowKey);
    [self close];
}
@end

#pragma mark - 设置主界面

@interface WXKSettingsViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<WXKRow *> *> *sections;
@end

@interface WXKSettingsViewController ()
- (void)prefsChanged:(NSNotification *)note;
- (void)buildRows;
- (void)close;
- (void)showText:(NSString *)title body:(NSString *)body;
- (void)shareExports;
- (void)alert:(NSString *)title message:(NSString *)message;
- (void)switchChanged:(UISwitch *)toggle;
@end

@implementation WXKSettingsViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"WXKit 设置";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(close)];
    [self buildRows];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(prefsChanged:)
                                                 name:WXKPrefsChangedNotification
                                               object:nil];
}

- (void)prefsChanged:(NSNotification *)note {
    [self buildRows];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildRows {
    WXKPrefs *prefs = [WXKPrefs shared];
    NSMutableArray<NSArray<WXKRow *> *> *sections = [NSMutableArray array];

    // 0. 状态
    NSMutableArray *status = [NSMutableArray array];
    WXKRow *version = [WXKRow row:WXKRowKindInfo title:@"WXKit 版本" key:nil];
    version.detail = WXK_VERSION;
    [status addObject:version];
    WXKRow *wechat = [WXKRow row:WXKRowKindInfo title:@"微信版本" key:nil];
    wechat.detail = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    [status addObject:wechat];
    NSInteger attached = 0;
    for (WXKHookRecord *r in [WXKHook records]) if (r.attached) attached++;
    WXKRow *hooks = [WXKRow row:WXKRowKindInfo title:@"已生效 hook" key:nil];
    hooks.detail = [NSString stringWithFormat:@"%ld 个", (long)attached];
    [status addObject:hooks];
    WXKRow *aiStatus = [WXKRow row:WXKRowKindInfo title:@"AI 最近状态" key:nil];
    aiStatus.detail = [WXKAI lastStatus];
    [status addObject:aiStatus];

    WXKRow *detail = [WXKRow row:WXKRowKindAction title:@"查看 hook / 探测报告" key:nil];
    __weak typeof(self) weakSelf = self;
    detail.action = ^{ [weakSelf showText:@"依赖探测报告" body:[WXKBridge diagnosticReport]]; };
    [status addObject:detail];

    WXKRow *selfTest = [WXKRow row:WXKRowKindAction title:@"运行自检（装好后先点这个）" key:nil];
    selfTest.detail = @"检查服务、hook、配置是否都通";
    selfTest.action = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *report = [WXKSelfTest run];
            [WXKDiagnostics writeText:report fileName:@"wxkit-selftest.txt"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showText:@"WXKit 自检" body:report];
            });
        });
    };
    [status addObject:selfTest];

    WXKRow *exportRow = [WXKRow row:WXKRowKindAction title:@"导出文件（分享给维护者）" key:nil];
    exportRow.detail = @"日志 / 类名 / 自检 / 撤回记录";
    exportRow.action = ^{ [weakSelf shareExports]; };
    [status addObject:exportRow];

    WXKRow *probe = [WXKRow row:WXKRowKindAction title:@"自动探测 hook 目标（推荐先发这个）" key:nil];
    probe.detail = @"几行文本，带方法签名，比全量类名省事";
    probe.action = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *report = [WXKDiagnostics hookProbeReport];
            [WXKDiagnostics writeText:report fileName:@"wxkit-hook-probe.txt"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showText:@"hook 目标探测（把这段发我）" body:report];
            });
        });
    };
    [status addObject:probe];

    WXKRow *dump = [WXKRow row:WXKRowKindAction title:@"导出类名与方法（关键）" key:nil];
    dump.action = ^{
        __strong WXKSettingsViewController *strongSelf = weakSelf;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *text = [WXKDiagnostics buildClassDumpWithMethodKeywords:@[]
                                                                        limit:8 * 1024 * 1024];
            [WXKDiagnostics writeText:text fileName:WXK_CLASS_DUMP_FILE];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf showText:@"类名导出结果" body:text];
            });
        });
    };
    [status addObject:dump];

    WXKRow *logs = [WXKRow row:WXKRowKindAction title:@"查看日志" key:nil];
    logs.action = ^{
        NSArray<NSString *> *lines = WXKLogSnapshot();
        NSString *text = [lines componentsJoinedByString:@"\n"];
        [weakSelf showText:@"WXKit 日志" body:text.length ? text : @"(暂无日志)"];
    };
    [status addObject:logs];
    [sections addObject:status];

    // 1. 通用
    NSMutableArray *general = [NSMutableArray array];
    [general addObject:[WXKRow row:WXKRowKindSwitch title:@"启用 WXKit" key:WXKKeyEnabled]];
    [general addObject:[WXKRow row:WXKRowKindSwitch title:@"显示悬浮球" key:WXKKeyFloating]];
    [general addObject:[WXKRow row:WXKRowKindSwitch title:@"详细日志" key:WXKKeyVerboseLog]];
    WXKRow *contentLog = [WXKRow row:WXKRowKindSwitch title:@"日志记录消息正文" key:WXKKeyLogContent];
    contentLog.detail = @"默认关；开启后日志里会含聊天内容";
    [general addObject:contentLog];
    [sections addObject:general];

    // 2. 防撤回
    NSMutableArray *recall = [NSMutableArray array];
    [recall addObject:[WXKRow row:WXKRowKindSwitch title:@"防撤回" key:WXKKeyRecallEnabled]];
    [recall addObject:[WXKRow row:WXKRowKindSwitch title:@"撤回时屏幕内提示原文" key:WXKKeyRecallToast]];
    WXKRow *keep = [WXKRow row:WXKRowKindNumber title:@"最多保留撤回记录" key:WXKKeyRecallKeep];
    [recall addObject:keep];
    WXKRow *records = [WXKRow row:WXKRowKindAction title:@"查看撤回记录" key:nil];
    records.action = ^{
        NSArray<NSDictionary *> *items = [WXKMsgStore recallRecords];
        NSMutableString *text = [NSMutableString string];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss";
        for (NSDictionary *item in items) {
            [text appendFormat:@"[%@] %@\n  %@\n\n",
                [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"time"] doubleValue]]],
                item[@"sender"], item[@"content"]];
        }
        [weakSelf showText:@"撤回记录" body:text.length ? text : @"(还没有记录)"];
    };
    [recall addObject:records];
    WXKRow *clearRecall = [WXKRow row:WXKRowKindAction title:@"清空撤回记录" key:nil];
    clearRecall.action = ^{
        [WXKMsgStore clearRecallRecords];
        [weakSelf.tableView reloadData];
    };
    [recall addObject:clearRecall];
    [sections addObject:recall];

    // 3. AI
    NSMutableArray *ai = [NSMutableArray array];
    [ai addObject:[WXKRow row:WXKRowKindSwitch title:@"AI 自动回复" key:WXKKeyAIEnabled]];
    [ai addObject:[WXKRow row:WXKRowKindText title:@"接口地址 (Base URL)" key:WXKKeyAIBaseURL]];
    WXKRow *keyRow = [WXKRow row:WXKRowKindText title:@"API Key" key:WXKKeyAIAPIKey];
    keyRow.secure = YES;
    [ai addObject:keyRow];
    [ai addObject:[WXKRow row:WXKRowKindText title:@"模型名" key:WXKKeyAIModel]];
    WXKRow *prompt = [WXKRow row:WXKRowKindText title:@"系统提示词" key:WXKKeyAISystemPrompt];
    prompt.multiline = YES;
    [ai addObject:prompt];
    [ai addObject:[WXKRow row:WXKRowKindSwitch title:@"只回私聊" key:WXKKeyAIPrivateOnly]];
    [ai addObject:[WXKRow row:WXKRowKindSwitch title:@"群里仅 @我 时回复" key:WXKKeyAIGroupMentionOnly]];
    [ai addObject:[WXKRow row:WXKRowKindNumber title:@"同会话冷却（秒）" key:WXKKeyAICooldown]];
    [ai addObject:[WXKRow row:WXKRowKindNumber title:@"回复最大字数" key:WXKKeyAIMaxLength]];
    [ai addObject:[WXKRow row:WXKRowKindNumber title:@"携带上下文条数" key:WXKKeyAIContextMessages]];
    [ai addObject:[WXKRow row:WXKRowKindNumber title:@"温度 temperature" key:WXKKeyAITemperature]];
    WXKRow *test = [WXKRow row:WXKRowKindAction title:@"测试连接" key:nil];
    test.action = ^{
        [weakSelf alert:@"正在测试…" message:nil];
        [WXKAI testConnection:^(BOOL ok, NSString *message) {
            [weakSelf alert:ok ? @"连接正常" : @"连接失败" message:message];
        }];
    };
    [ai addObject:test];
    [sections addObject:ai];

    // 4. 适配：改候选名不用重新编译注入
    NSMutableArray *adapt = [NSMutableArray array];
    WXKRow *overrideRow = [WXKRow row:WXKRowKindText title:@"候选名覆盖（适配用）" key:WXKKeyOverrideText];
    overrideRow.multiline = YES;
    [adapt addObject:overrideRow];

    WXKRow *candidates = [WXKRow row:WXKRowKindAction title:@"查看当前生效的候选名" key:nil];
    candidates.detail = @"确认覆盖是否生效";
    candidates.action = ^{ [weakSelf showText:@"当前生效候选名" body:[WXKBridge candidateReport]]; };
    [adapt addObject:candidates];

    WXKRow *retry = [WXKRow row:WXKRowKindAction title:@"重试挂载消息回调" key:nil];
    retry.detail = [WXKBridge messageHooksInstalled] ? @"已挂上" : @"尚未挂上，改完候选名点这里";
    retry.action = ^{
        BOOL ok = [WXKBridge installMessageHooks];
        [weakSelf alert:(ok ? @"已挂上消息回调" : @"仍然没找到")
                message:(ok ? @"收发一条消息，再点「查看日志」确认。"
                            : @"请在上面的「候选名覆盖」里填好 msgclass 与 incoming 再重试，或导出类名发给维护者。")];
        [weakSelf buildRows];
    };
    [adapt addObject:retry];
    [sections addObject:adapt];

    self.sections = sections;
    [self.tableView reloadData];
}

- (void)showText:(NSString *)title body:(NSString *)body {
    WXKTextPageViewController *page = [[WXKTextPageViewController alloc] init];
    page.pageTitle = title;
    page.body = body;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    [self presentViewController:nav animated:YES completion:nil];
}

// 把容器里可导出的文件一次性分享出去（AirDrop / 存到"文件" / 发给维护者）
- (void)shareExports {
    NSArray<NSURL *> *urls = [WXKDiagnostics exportableFileURLs];
    if (!urls.count) {
        [self alert:@"还没有可导出的文件" message:@"先点「运行自检」或「导出类名与方法」生成文件。"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:urls
                                                                           applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"状态", @"通用", @"防撤回", @"AI 自动回复", @"适配（候选名覆盖）"][section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WXKRow *row = self.sections[indexPath.section][indexPath.row];
    static NSString *identifier = @"WXKCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.detail;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    switch (row.kind) {
        case WXKRowKindSwitch: {
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = [[WXKPrefs shared] boolForKey:row.key];
            toggle.tag = indexPath.section * 1000 + indexPath.row;
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            objc_setAssociatedObject(toggle, @selector(switchChanged:), row.key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case WXKRowKindText:
        case WXKRowKindNumber: {
            if ([row.key isEqualToString:WXKKeyOverrideText]) {
                NSString *summary = [WXKOverrides summary];
                cell.detailTextLabel.text = summary.length > 70
                    ? [[summary substringToIndex:70] stringByAppendingString:@"…"] : summary;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            NSString *value = [[WXKPrefs shared] stringForKey:row.key] ?: @"";
            if (row.secure && value.length) {
                cell.detailTextLabel.text = @"••••••";
            } else {
                cell.detailTextLabel.text = value.length > 60 ? [[value substringToIndex:60] stringByAppendingString:@"…"] : value;
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case WXKRowKindAction:
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case WXKRowKindInfo:
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)toggle {
    NSString *key = objc_getAssociatedObject(toggle, @selector(switchChanged:));
    [[WXKPrefs shared] setBool:toggle.isOn forKey:key];
    if ([key isEqualToString:WXKKeyFloating]) {
        [WXKFloating setVisible:toggle.isOn];
    }
    [self buildRows];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WXKRow *row = self.sections[indexPath.section][indexPath.row];
    if (row.kind == WXKRowKindAction) {
        if (row.action) row.action();
        return;
    }
    if (row.kind == WXKRowKindInfo) {
        return;
    }
    WXKValueEditorViewController *editor = [[WXKValueEditorViewController alloc] init];
    editor.rowTitle = row.title;
    editor.rowKey = row.key;
    editor.kind = row.kind;
    editor.secure = row.secure;
    editor.multiline = row.multiline;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    [self presentViewController:nav animated:YES completion:nil];
}

@end

@implementation WXKSettings

+ (void)present {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = WXKTopViewController();
        if (!top) {
            WXKLog(@"[ui] 找不到可以弹窗的控制器");
            return;
        }
        WXKSettingsViewController *settings = [[WXKSettingsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:nav animated:YES completion:nil];
    });
}

+ (void)presentTextPageWithTitle:(NSString *)title text:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = WXKTopViewController();
        if (!top) return;
        WXKTextPageViewController *page = [[WXKTextPageViewController alloc] init];
        page.pageTitle = title;
        page.body = text;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

@end
