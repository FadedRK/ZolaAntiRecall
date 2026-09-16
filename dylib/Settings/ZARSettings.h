#import <UIKit/UIKit.h>

@interface ZARSettings : NSObject

+ (instancetype)sharedInstance;

/// 是否显示自己撤回的消息。YES = 拦截自己撤回并显示原文；NO = 正常撤回。
@property (nonatomic, assign) BOOL showMyRecallEnabled;

@end

#ifdef __cplusplus
extern "C" {
#endif

void ZARInstallSettings(void);

#ifdef __cplusplus
}
#endif
